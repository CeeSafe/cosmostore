// cosmostore-bench: an S3 load generator for M4 (ADR-0021), after the architecture's benchmark plan (§9). For each
// object size and concurrency it runs PUT, GET (every body verified), HEAD, overwrite and DELETE phases on its own
// keys, and reports ops/s, MiB/s and p50/p95/p99/p99.9 latency. Around each phase it reads the server's
// `/_cosmostore/stats` for syncs per 1,000 writes and write amplification, and (with -pid) the server's RSS.
//
// Requests are signed SigV4 with UNSIGNED-PAYLOAD, as an SDK over TLS often sends them; the bytes are checked by
// MD5 on every GET instead. Object bodies come from the seed and the key, so a run is repeatable.
package main

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	v4 "github.com/aws/aws-sdk-go-v2/aws/signer/v4"
)

type phaseResult struct {
	Size         int     `json:"size"`
	Concurrency  int     `json:"concurrency"`
	Op           string  `json:"op"`
	Ops          int     `json:"ops"`
	Errors       int     `json:"errors"`
	Seconds      float64 `json:"seconds"`
	OpsPerSec    float64 `json:"opsPerSec"`
	MiBPerSec    float64 `json:"mibPerSec"`
	P50          float64 `json:"p50ms"`
	P95          float64 `json:"p95ms"`
	P99          float64 `json:"p99ms"`
	P999         float64 `json:"p999ms"`
	Max          float64 `json:"maxms"`
	SyncsPer1k   float64 `json:"syncsPer1kOps"`
	WriteAmp     float64 `json:"writeAmplification"`
	ServerRSSMiB float64 `json:"serverRssMiB"`
}

type report struct {
	Label       string        `json:"label"`
	Started     string        `json:"started"`
	Endpoint    string        `json:"endpoint"`
	Host        string        `json:"host"`
	CPU         string        `json:"cpu"`
	OS          string        `json:"os"`
	GoVersion   string        `json:"go"`
	Seed        int64         `json:"seed"`
	OpsPerPhase int           `json:"opsPerPhase"`
	Results     []phaseResult `json:"results"`
}

var (
	endpoint = flag.String("endpoint", "http://127.0.0.1:9000", "server URL")
	bucket   = flag.String("bucket", "bench", "bucket (created if missing)")
	sizesArg = flag.String("sizes", "0,128,1024,4096,16384,65536,262144,1048576", "object sizes in bytes")
	concArg  = flag.String("concurrency", "1,8,32,128", "concurrency levels")
	opsArg   = flag.Int("ops", 2000, "operations per phase (fewer for objects over 1 MiB)")
	seed     = flag.Int64("seed", 1, "seed for keys and bodies")
	pid      = flag.Int("pid", 0, "the server's process id, to sample its RSS")
	label    = flag.String("label", "", "what is being measured (commit, build, settings)")
	jsonOut  = flag.String("json", "", "write the results as JSON here")
	// GET checks each body against the original bytes, so it runs before overwrite in the default order.
	phases = flag.String("phases", "put,get,head,overwrite,delete", "phases to run, in order")
)

var (
	signer  = v4.NewSigner()
	creds   aws.Credentials
	client  *http.Client
	emptySH = hex.EncodeToString(sha256.New().Sum(nil))
)

func request(method, path string, body []byte) (*http.Request, error) {
	req, err := http.NewRequest(method, *endpoint+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.ContentLength = int64(len(body))
	req.Header.Set("x-amz-content-sha256", "UNSIGNED-PAYLOAD")
	err = signer.SignHTTP(context.Background(), creds, req, "UNSIGNED-PAYLOAD", "s3", "us-east-1", time.Now())
	return req, err
}

func do(method, path string, body []byte) (int, []byte, error) {
	req, err := request(method, path, body)
	if err != nil {
		return 0, nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	return resp.StatusCode, data, err
}

// bodyOf is the object for key i of a size: bytes from the seed, the size and i.
func bodyOf(size, i int) []byte {
	r := rand.New(rand.NewSource(*seed ^ int64(size)<<20 ^ int64(i)))
	b := make([]byte, size)
	r.Read(b)
	return b
}

func keyOf(size, conc, i int) string { return fmt.Sprintf("/%s/s%d/c%d/k%06d", *bucket, size, conc, i) }

type stats map[string]float64

func serverStats() stats {
	_, data, err := do("GET", "/_cosmostore/stats", nil)
	s := stats{}
	if err == nil {
		json.Unmarshal(data, &s)
	}
	return s
}

func serverRSS() float64 {
	if *pid == 0 {
		return 0
	}
	out, err := exec.Command("ps", "-o", "rss=", "-p", strconv.Itoa(*pid)).Output()
	if err != nil {
		return 0
	}
	kb, _ := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	return kb / 1024
}

func percentile(sorted []time.Duration, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	i := int(float64(len(sorted)-1) * p)
	return float64(sorted[i].Microseconds()) / 1000
}

// runPhase performs n operations of op with conc workers and measures them.
func runPhase(op string, size, conc, n int, bodies [][]byte, sums [][16]byte) phaseResult {
	before := serverStats()
	lat := make([]time.Duration, n)
	var next, errs int64 = -1, 0
	var wg sync.WaitGroup
	start := time.Now()
	for w := 0; w < conc; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				i := int(atomic.AddInt64(&next, 1))
				if i >= n {
					return
				}
				key := keyOf(size, conc, i)
				t0 := time.Now()
				var status int
				var data []byte
				var err error
				switch op {
				case "put", "overwrite":
					body := bodies[i]
					if op == "overwrite" {
						body = append([]byte(nil), body...)
						if len(body) > 0 {
							body[0] ^= 0xFF
						}
					}
					status, _, err = do("PUT", key, body)
				case "get":
					status, data, err = do("GET", key, nil)
					if err == nil && status == 200 && md5.Sum(data) != sums[i] {
						err = fmt.Errorf("GET %s: the bytes differ", key)
					}
				case "head":
					status, _, err = do("HEAD", key, nil)
				case "delete":
					status, _, err = do("DELETE", key, nil)
				}
				lat[i] = time.Since(t0)
				if err != nil || status >= 300 {
					if atomic.AddInt64(&errs, 1) <= 3 {
						fmt.Fprintf(os.Stderr, "bench: %s %s: status %d, %v\n", op, key, status, err)
					}
				}
			}
		}()
	}
	wg.Wait()
	elapsed := time.Since(start).Seconds()
	after := serverStats()
	sorted := append([]time.Duration(nil), lat...)
	sort.Slice(sorted, func(a, b int) bool { return sorted[a] < sorted[b] })
	res := phaseResult{
		Size: size, Concurrency: conc, Op: op, Ops: n, Errors: int(errs), Seconds: elapsed,
		OpsPerSec: float64(n) / elapsed,
		P50: percentile(sorted, 0.50), P95: percentile(sorted, 0.95), P99: percentile(sorted, 0.99),
		P999: percentile(sorted, 0.999), Max: percentile(sorted, 1.0), ServerRSSMiB: serverRSS(),
	}
	if op != "head" && op != "delete" {
		res.MiBPerSec = float64(n) * float64(size) / elapsed / (1 << 20)
	}
	if len(before) > 0 && len(after) > 0 {
		res.SyncsPer1k = (after["journalSyncs"] - before["journalSyncs"]) / float64(n) * 1000
		payload := after["payloadBytes"] - before["payloadBytes"]
		written := (after["journalBytesWritten"] + after["extentBytesWritten"] + after["checkpointBytesWritten"]) -
			(before["journalBytesWritten"] + before["extentBytesWritten"] + before["checkpointBytesWritten"])
		if payload > 0 {
			res.WriteAmp = written / payload
		}
	}
	return res
}

func ints(s string) []int {
	var out []int
	for _, f := range strings.Split(s, ",") {
		if v, err := strconv.Atoi(strings.TrimSpace(f)); err == nil {
			out = append(out, v)
		}
	}
	return out
}

func sh(name string, args ...string) string {
	out, err := exec.Command(name, args...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func main() {
	flag.Parse()
	creds = aws.Credentials{AccessKeyID: os.Getenv("AWS_ACCESS_KEY_ID"), SecretAccessKey: os.Getenv("AWS_SECRET_ACCESS_KEY")}
	conc := ints(*concArg)
	maxConc := 0
	for _, c := range conc {
		if c > maxConc {
			maxConc = c
		}
	}
	client = &http.Client{Transport: &http.Transport{MaxIdleConnsPerHost: maxConc, MaxConnsPerHost: maxConc}}
	if status, _, err := do("PUT", "/"+*bucket, nil); err != nil || (status != 200 && status != 409) {
		fmt.Fprintf(os.Stderr, "bench: cannot create the bucket: status %d, %v\n", status, err)
		os.Exit(1)
	}
	rep := report{
		Label: *label, Started: time.Now().UTC().Format(time.RFC3339), Endpoint: *endpoint,
		Host: sh("hostname", "-s"), CPU: sh("sysctl", "-n", "machdep.cpu.brand_string"),
		OS: runtime.GOOS + " " + sh("uname", "-r"), GoVersion: runtime.Version(), Seed: *seed, OpsPerPhase: *opsArg,
	}
	fmt.Printf("| size | conc | op | ops/s | MiB/s | p50 ms | p95 ms | p99 ms | p99.9 ms | syncs/1k | write amp | RSS MiB | errors |\n")
	fmt.Printf("|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n")
	failed := false
	for _, size := range ints(*sizesArg) {
		n := *opsArg
		if size > 1<<20 {
			n = max(n*(1<<20)/size, 50)
		}
		bodies := make([][]byte, n)
		sums := make([][16]byte, n)
		for i := range bodies {
			bodies[i] = bodyOf(size, i)
			sums[i] = md5.Sum(bodies[i])
		}
		for _, c := range conc {
			for _, op := range strings.Split(*phases, ",") {
				r := runPhase(op, size, c, n, bodies, sums)
				rep.Results = append(rep.Results, r)
				if r.Errors > 0 {
					failed = true
				}
				fmt.Printf("| %d | %d | %s | %.0f | %.1f | %.2f | %.2f | %.2f | %.2f | %.1f | %.2f | %.0f | %d |\n",
					r.Size, r.Concurrency, r.Op, r.OpsPerSec, r.MiBPerSec, r.P50, r.P95, r.P99, r.P999,
					r.SyncsPer1k, r.WriteAmp, r.ServerRSSMiB, r.Errors)
			}
		}
	}
	if *jsonOut != "" {
		data, _ := json.MarshalIndent(rep, "", "  ")
		os.WriteFile(*jsonOut, data, 0o644)
	}
	if failed {
		os.Exit(1)
	}
}
