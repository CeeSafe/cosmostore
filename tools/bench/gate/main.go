// Command gate checks tools/bench results (ADR-0030).
//
// Two modes:
//
//	gate -base a1.json,a2.json,… -head b1.json,b2.json,…
//	    The regression gate: compares runs of two builds made in turns on the same machine (tools/perf_gate.sh), one
//	    base and one head run per round, given in round order. Each phase's p99 and throughput become head-to-base
//	    ratios within a round, then the median over the rounds; a group of phases (writes, GETs or metadata reads,
//	    small or large, at one concurrency) fails when the geometric mean of its ratios passes the tolerance. A phase fails on
//	    errors or more syncs per 1,000 writes. Only ratios count, so it runs on any machine (CI).
//
//	gate -targets tools/bench/targets.json [-run matrix.json] [-scale dir-or-file]
//	    The targets of docs/targets.md, checked against one run on the reference machine.
//
// It prints a Markdown report and exits 1 if anything fails, 2 on bad input, and 3 if a comparison was too noisy to
// judge.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type phase struct {
	Size        int     `json:"size"`
	Concurrency int     `json:"concurrency"`
	Op          string  `json:"op"`
	Ops         int     `json:"ops"`
	Errors      int     `json:"errors"`
	OpsPerSec   float64 `json:"opsPerSec"`
	MiBPerSec   float64 `json:"mibPerSec"`
	P50         float64 `json:"p50ms"`
	P99         float64 `json:"p99ms"`
	P999        float64 `json:"p999ms"`
	SyncsPer1k  float64 `json:"syncsPer1kOps"`
	WriteAmp    float64 `json:"writeAmplification"`
}

type run struct {
	Label   string  `json:"label"`
	Results []phase `json:"results"`
}

type key struct {
	size, conc int
	op         string
}

func (k key) String() string { return fmt.Sprintf("%d B, c%d, %s", k.size, k.conc, k.op) }

var (
	baseArg    = flag.String("base", "", "comma-separated result files of the base build")
	headArg    = flag.String("head", "", "comma-separated result files of the build under test")
	p99Tol     = flag.Float64("p99-tolerance", 0.25, "allowed rise of a write group's p99, head over base")
	readP99Tol = flag.Float64("read-p99-tolerance", 0.50, "allowed rise of a read group's p99, head over base")
	p99Slack   = flag.Float64("p99-slack-ms", 2.0, "ms added to every p99 before taking ratios, so sub-millisecond jitter does not count")
	opsTol     = flag.Float64("ops-tolerance", 0.20, "allowed fall of a group's throughput, head over base")
	maxNoise   = flag.Float64("max-noise", 2.0, "the median group noise above which a run is inconclusive")
	syncsTol   = flag.Float64("syncs-tolerance", 0.25, "allowed relative rise of a phase's syncs per 1,000 writes")
	syncsSlack = flag.Float64("syncs-slack", 5, "allowed absolute rise of a phase's syncs per 1,000 writes")
	targetsArg = flag.String("targets", "", "targets file (tools/bench/targets.json)")
	runArg     = flag.String("run", "", "matrix results to check against the targets")
	scaleArg   = flag.String("scale", "", "scale results to check against the targets: tools/scale.sh's OUT directory, or a merged file")
)

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "gate: "+format+"\n", args...)
	os.Exit(2)
}

func load(path string, into any) {
	data, err := os.ReadFile(path)
	if err != nil {
		die("%v", err)
	}
	if err := json.Unmarshal(data, into); err != nil {
		die("%s: %v", path, err)
	}
}

func loadRuns(list string) []run {
	var runs []run
	for _, p := range strings.Split(list, ",") {
		if p = strings.TrimSpace(p); p != "" {
			var r run
			load(p, &r)
			if len(r.Results) == 0 {
				die("%s: no results", p)
			}
			runs = append(runs, r)
		}
	}
	return runs
}

func median(v []float64) float64 {
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

func minMax(v []float64) (float64, float64) {
	lo, hi := math.Inf(1), math.Inf(-1)
	for _, x := range v {
		lo, hi = math.Min(lo, x), math.Max(hi, x)
	}
	return lo, hi
}

// samples gathers each phase's results across runs, in the first run's order.
func samples(runs []run) ([]key, map[key][]phase) {
	var order []key
	byKey := map[key][]phase{}
	for _, r := range runs {
		for _, p := range r.Results {
			k := key{p.Size, p.Concurrency, p.Op}
			if _, seen := byKey[k]; !seen {
				order = append(order, k)
			}
			byKey[k] = append(byKey[k], p)
		}
	}
	return order, byKey
}

func pick(ps []phase, f func(phase) float64) []float64 {
	v := make([]float64, len(ps))
	for i, p := range ps {
		v[i] = f(p)
	}
	return v
}

func isWrite(op string) bool { return op == "put" || op == "overwrite" || op == "delete" }

// A group is the phases one kind of change would move together, at one concurrency: writes (PUT, overwrite, DELETE),
// GETs that read a record, and metadata reads (HEAD, and GET of an empty object), of small objects (up to 64 KiB) or
// large. DELETE and the metadata reads move no object bytes, so they count with the small objects at every size. The
// gate fails on a group, not a phase: noise moves single phases, and a regression in the store moves a group.
type group struct {
	kind  string
	large bool
	conc  int
}

func (g group) String() string {
	size := "small"
	if g.large {
		size = "large"
	}
	return fmt.Sprintf("%s %s, c%d", size, g.kind, g.conc)
}

func groupOf(k key) group {
	kind := "writes"
	switch {
	case k.op == "head" || (k.op == "get" && k.size == 0):
		kind = "metadata reads"
	case k.op == "get":
		kind = "GETs"
	}
	large := k.size > 65536 && kind != "metadata reads" && k.op != "delete"
	return group{kind, large, k.conc}
}

// ratios pairs each head run with the base run of the same round, which ran just before or after it on the same
// machine, and gives the median of the head-to-base ratios.
func pairedRatio(b, h []phase, f func(phase) float64) float64 {
	var r []float64
	for i := range h {
		r = append(r, f(h[i])/f(b[i]))
	}
	return median(r)
}

func compare() bool {
	base, head := loadRuns(*baseArg), loadRuns(*headArg)
	if len(base) == 0 || len(base) != len(head) {
		die("-base and -head need the same number of runs, one of each per round")
	}
	order, b := samples(base)
	_, h := samples(head)
	slack := *p99Slack
	p99Of := func(p phase) float64 { return p.P99 + slack }
	opsOf := func(p phase) float64 { return p.OpsPerSec }

	type tally struct {
		logP99, logOps           float64 // head over base
		logP99Noise, logOpsNoise float64 // the base's own spread: its slowest round over its fastest
		n                        int
	}
	groups := map[group]*tally{}
	var groupOrder []group
	var phaseFails []string
	var rows strings.Builder
	for _, k := range order {
		hs := h[k]
		if len(hs) != len(b[k]) {
			phaseFails = append(phaseFails, k.String()+": missing from some runs")
			continue
		}
		p99r, opsr := pairedRatio(b[k], hs, p99Of), pairedRatio(b[k], hs, opsOf)
		g := groupOf(k)
		t := groups[g]
		if t == nil {
			t = &tally{}
			groups[g] = t
			groupOrder = append(groupOrder, g)
		}
		lo99, hi99 := minMax(pick(b[k], p99Of))
		loOps, hiOps := minMax(pick(b[k], opsOf))
		t.logP99Noise += math.Log(hi99 / lo99)
		t.logOpsNoise += math.Log(hiOps / loOps)
		t.logP99 += math.Log(p99r)
		t.logOps += math.Log(opsr)
		t.n++
		var why []string
		errors := 0
		for _, p := range hs {
			errors += p.Errors
		}
		if errors > 0 {
			why = append(why, fmt.Sprintf("%d errors", errors))
		}
		bsy := median(pick(b[k], func(p phase) float64 { return p.SyncsPer1k }))
		hsy := median(pick(hs, func(p phase) float64 { return p.SyncsPer1k }))
		if isWrite(k.op) {
			if limit := bsy*(1+*syncsTol) + *syncsSlack; hsy > limit {
				why = append(why, fmt.Sprintf("syncs/1k above %.0f", limit))
			}
		}
		verdict := ""
		if len(why) > 0 {
			verdict = "**FAIL:** " + strings.Join(why, "; ")
			phaseFails = append(phaseFails, k.String()+": "+strings.Join(why, "; "))
		}
		fmt.Fprintf(&rows, "| %s | %.2f | %.2f | %.2f | %.0f | %.0f | %.2f | %.0f | %.0f | %s |\n", k,
			median(pick(b[k], func(p phase) float64 { return p.P99 })), median(pick(hs, func(p phase) float64 { return p.P99 })), p99r,
			median(pick(b[k], opsOf)), median(pick(hs, opsOf)), opsr, bsy, hsy, verdict)
	}

	fmt.Printf("# Regression gate\n\n%d rounds, each running the base and the head build in turn. Each head run is compared with the\n", len(base))
	fmt.Printf("base run of its round; a phase's ratio is the median over the rounds (p99 with %.1f ms added to both sides).\n", slack)
	fmt.Printf("A group fails when the geometric mean of its phases' ratios passes the tolerance: p99 × %.2f for writes and\n", 1+*p99Tol)
	fmt.Printf("× %.2f for reads, ops/s × %.2f.\n", 1+*readP99Tol, 1-*opsTol)
	fmt.Printf("A phase fails on errors, or on syncs per 1,000 writes above the base's × %.2f + %.0f.\n\n", 1+*syncsTol, *syncsSlack)
	fmt.Println("A group fails only if it is also past the base's own spread between rounds (its noise); one past the tolerance")
	fmt.Println("but within its noise is reported as noisy. When the median group noise is above")
	fmt.Printf("%.2f, the machine was too busy to tell, and the run is inconclusive unless a phase failed.\n\n", *maxNoise)
	fmt.Println("| group | phases | p99, head / base | ops/s, head / base | noise, p99 / ops/s | |")
	fmt.Println("|---|---:|---:|---:|---:|---|")
	groupsOK := true
	var noises []float64
	for _, g := range groupOrder {
		t := groups[g]
		p99 := math.Exp(t.logP99 / float64(t.n))
		ops := math.Exp(t.logOps / float64(t.n))
		n99 := math.Exp(t.logP99Noise / float64(t.n))
		nOps := math.Exp(t.logOpsNoise / float64(t.n))
		noises = append(noises, math.Max(n99, nOps))
		tol := *p99Tol
		if g.kind != "writes" {
			tol = *readP99Tol
		}
		var why, noisy []string
		if p99 > 1+tol {
			if p99 > n99 {
				why = append(why, "p99")
			} else {
				noisy = append(noisy, "p99")
			}
		}
		if ops < 1-*opsTol {
			if 1/ops > nOps {
				why = append(why, "ops/s")
			} else {
				noisy = append(noisy, "ops/s")
			}
		}
		verdict := "ok"
		switch {
		case len(why) > 0:
			verdict = "**FAIL:** " + strings.Join(why, ", ")
			groupsOK = false
		case len(noisy) > 0:
			verdict = "noisy: " + strings.Join(noisy, ", ") + " within the base's spread"
		}
		fmt.Printf("| %s | %d | %.2f | %.2f | %.2f / %.2f | %s |\n", g, t.n, p99, ops, n99, nOps, verdict)
	}
	fmt.Println("\n| phase | base p99 ms | head p99 ms | ratio | base ops/s | head ops/s | ratio | base syncs/1k | head syncs/1k | |")
	fmt.Println("|---|---:|---:|---:|---:|---:|---:|---:|---:|---|")
	fmt.Print(rows.String())
	for _, f := range phaseFails {
		fmt.Printf("\n**FAIL:** %s", f)
	}
	// Errors and syncs per write do not depend on the machine's load, so they fail however noisy the run.
	if len(phaseFails) > 0 {
		return false
	}
	if noise := median(noises); noise > *maxNoise {
		fmt.Printf("\nThe run's noise is %.2f, above %.2f: the groups' verdicts are not trusted.\n", noise, *maxNoise)
		inconclusive = true
		return true
	}
	return groupsOK
}

// inconclusive is set when a comparison found no failure but was too noisy to trust.
var inconclusive bool

// The targets file (tools/bench/targets.json).
type target struct {
	Target      string             `json:"target"`
	What        string             `json:"what"`
	Ops         []string           `json:"ops"`
	Sizes       []int              `json:"sizes"`            // empty: every size in the run
	MaxSize     int                `json:"maxSize"`          // 0: no limit
	Concurrency int                `json:"concurrency"`      // 0: every level
	Min         map[string]float64 `json:"min"`              // metric name (as in the results) to its least value
	Max         map[string]float64 `json:"max"`              // metric name to its greatest value
	NotBelow    []string           `json:"notBelowBaseline"` // metrics that may not fall below the baseline's
	NotAbove    []string           `json:"notAboveBaseline"` // metrics that may not rise above the baseline's
	Weighted    map[string]float64 `json:"weightedMax"`      // metric averaged over the phases by bytes written
}

type targets struct {
	Machine  string   `json:"machine"`
	Baseline string   `json:"baseline"` // relative to the targets file
	Matrix   []target `json:"matrix"`
	Scale    struct {
		MaxBytesPerObject  float64 `json:"maxBytesPerObject"`
		MaxGrowth          float64 `json:"maxGrowth"`
		MaxListP99         float64 `json:"maxListP99ms"`
		MaxRecoverySeconds float64 `json:"maxRecoverySeconds"`
	} `json:"scale"`
}

func metric(p phase, name string) float64 {
	switch name {
	case "opsPerSec":
		return p.OpsPerSec
	case "mibPerSec":
		return p.MiBPerSec
	case "p50ms":
		return p.P50
	case "p99ms":
		return p.P99
	case "p999ms":
		return p.P999
	case "syncsPer1kOps":
		return p.SyncsPer1k
	case "writeAmplification":
		return p.WriteAmp
	}
	die("unknown metric %q", name)
	return 0
}

func (t target) matches(p phase) bool {
	if (t.Concurrency != 0 && p.Concurrency != t.Concurrency) || (t.MaxSize > 0 && p.Size > t.MaxSize) {
		return false
	}
	opOK, sizeOK := false, len(t.Sizes) == 0
	for _, o := range t.Ops {
		opOK = opOK || o == p.Op
	}
	for _, s := range t.Sizes {
		sizeOK = sizeOK || s == p.Size
	}
	return opOK && sizeOK
}

func checkTargets() bool {
	var ts targets
	load(*targetsArg, &ts)
	var baseline map[key]phase
	if ts.Baseline != "" {
		var r run
		load(filepath.Join(filepath.Dir(*targetsArg), ts.Baseline), &r)
		baseline = map[key]phase{}
		for _, p := range r.Results {
			baseline[key{p.Size, p.Concurrency, p.Op}] = p
		}
	}
	fmt.Printf("# Targets (%s)\n\n", ts.Machine)
	ok := true
	if *runArg != "" {
		var r run
		load(*runArg, &r)
		fmt.Printf("Run: %s\n\n| # | target | phases | worst | |\n|---|---|---|---|---|\n", r.Label)
		for _, t := range ts.Matrix {
			var ps []phase
			for _, p := range r.Results {
				if t.matches(p) {
					ps = append(ps, p)
				}
			}
			if len(ps) == 0 {
				fmt.Printf("| %s | %s | none in the run | | skipped |\n", t.Target, t.What)
				continue
			}
			var fails, worst []string
			for _, p := range ps {
				if p.Errors > 0 {
					fails = append(fails, fmt.Sprintf("%s: %d errors", key{p.Size, p.Concurrency, p.Op}, p.Errors))
				}
			}
			for _, name := range sortedKeys(t.Min) {
				lo := ps[0]
				for _, p := range ps {
					if metric(p, name) < metric(lo, name) {
						lo = p
					}
					if metric(p, name) < t.Min[name] {
						fails = append(fails, fmt.Sprintf("%s: %s %.4g < %.4g", key{p.Size, p.Concurrency, p.Op}, name, metric(p, name), t.Min[name]))
					}
				}
				worst = append(worst, fmt.Sprintf("%s %.4g", name, metric(lo, name)))
			}
			for _, name := range sortedKeys(t.Max) {
				hi := ps[0]
				for _, p := range ps {
					if metric(p, name) > metric(hi, name) {
						hi = p
					}
					if metric(p, name) > t.Max[name] {
						fails = append(fails, fmt.Sprintf("%s: %s %.4g > %.4g", key{p.Size, p.Concurrency, p.Op}, name, metric(p, name), t.Max[name]))
					}
				}
				worst = append(worst, fmt.Sprintf("%s %.4g", name, metric(hi, name)))
			}
			for _, name := range append(append([]string(nil), t.NotBelow...), t.NotAbove...) {
				below := contains(t.NotBelow, name)
				for _, p := range ps {
					k := key{p.Size, p.Concurrency, p.Op}
					b, found := baseline[k]
					if !found {
						fails = append(fails, fmt.Sprintf("%s: not in the baseline", k))
						continue
					}
					if below && metric(p, name) < metric(b, name) {
						fails = append(fails, fmt.Sprintf("%s: %s %.4g < baseline %.4g", k, name, metric(p, name), metric(b, name)))
					}
					if !below && metric(p, name) > metric(b, name) {
						fails = append(fails, fmt.Sprintf("%s: %s %.4g > baseline %.4g", k, name, metric(p, name), metric(b, name)))
					}
				}
				worst = append(worst, name+" vs baseline")
			}
			for _, name := range sortedKeys(t.Weighted) {
				var sum, bytes float64
				for _, p := range ps {
					w := float64(p.Ops) * float64(p.Size)
					sum += metric(p, name) * w
					bytes += w
				}
				v := sum / bytes
				worst = append(worst, fmt.Sprintf("%s %.3g over the phases", name, v))
				if v > t.Weighted[name] {
					fails = append(fails, fmt.Sprintf("%s %.3g > %.3g", name, v, t.Weighted[name]))
				}
			}
			verdict := "met"
			if len(fails) > 0 {
				verdict = "**not met:** " + strings.Join(fails, "; ")
				ok = false
			}
			fmt.Printf("| %s | %s | %d | %s | %s |\n", t.Target, t.What, len(ps), strings.Join(worst, ", "), verdict)
		}
		fmt.Println()
	}
	if *scaleArg != "" {
		ok = checkScale(ts, *scaleArg) && ok
	}
	return ok
}

type scaleRow struct {
	Mode     string  `json:"mode"`
	Errors   int     `json:"errors"`
	P99      float64 `json:"p99ms"`
	Position string  `json:"position"`
}

func checkScale(ts targets, path string) bool {
	var s struct {
		Summary struct {
			Objects         float64 `json:"objects"`
			RSSEmpty        float64 `json:"rssEmptyMiB"`
			RSSIdle         float64 `json:"rssIdleMiB"`
			RSSListed       float64 `json:"rssListedMiB"`
			RSSRecovered    float64 `json:"rssRecoveredMiB"`
			RecoverySeconds float64 `json:"recoverySeconds"`
		} `json:"summary"`
		Fill          []scaleRow `json:"fill"`
		List          []scaleRow `json:"list"`
		ListRecovered []scaleRow `json:"list-recovered"`
	}
	if info, err := os.Stat(path); err == nil && info.IsDir() {
		// tools/scale.sh's OUT directory: the summary, and the generator's results, each under "scale".
		load(filepath.Join(path, "summary.json"), &s.Summary)
		for name, into := range map[string]*[]scaleRow{"fill": &s.Fill, "list": &s.List, "list-recovered": &s.ListRecovered} {
			var r struct {
				Scale []scaleRow `json:"scale"`
			}
			load(filepath.Join(path, name+".json"), &r)
			*into = r.Scale
		}
	} else {
		load(path, &s) // a merged file, as docs/benchmarks keeps them
	}
	sum := s.Summary
	if sum.Objects == 0 {
		die("%s: no summary", path)
	}
	perObject := func(mib float64) float64 { return (mib - sum.RSSEmpty) * 1048576 / sum.Objects }
	ok := true
	row := func(t, what, value string, met bool) {
		verdict := "met"
		if !met {
			verdict, ok = "**not met**", false
		}
		fmt.Printf("| %s | %s | %s | %s |\n", t, what, value, verdict)
	}
	sc := ts.Scale
	fmt.Printf("Scale: %.0f objects\n\n| # | target | value | |\n|---|---|---|---|\n", sum.Objects)
	idle, recovered := perObject(sum.RSSIdle), perObject(sum.RSSRecovered)
	row("T9", fmt.Sprintf("≤ %.0f bytes per object", sc.MaxBytesPerObject),
		fmt.Sprintf("%.0f idle, %.0f recovered", idle, recovered), idle <= sc.MaxBytesPerObject && recovered <= sc.MaxBytesPerObject)
	row("T9", fmt.Sprintf("no growth after the load (≤ %.0f%%)", sc.MaxGrowth*100),
		fmt.Sprintf("%.0f MiB idle, %.0f after listing", sum.RSSIdle, sum.RSSListed), sum.RSSListed <= sum.RSSIdle*(1+sc.MaxGrowth))
	worst, errors := 0.0, 0
	for _, rows := range [][]scaleRow{s.Fill, s.List, s.ListRecovered} {
		for _, r := range rows {
			errors += r.Errors
			if r.Mode == "list" {
				worst = math.Max(worst, r.P99)
			}
		}
	}
	row("T10", fmt.Sprintf("page of 1,000 ≤ %.0f ms p99", sc.MaxListP99), fmt.Sprintf("%.2f ms worst", worst), worst > 0 && worst <= sc.MaxListP99)
	row("T11", fmt.Sprintf("recovery ≤ %.0f s", sc.MaxRecoverySeconds), fmt.Sprintf("%.2f s", sum.RecoverySeconds),
		sum.RecoverySeconds > 0 && sum.RecoverySeconds <= sc.MaxRecoverySeconds)
	row("—", "no errors", fmt.Sprintf("%d", errors), errors == 0)
	fmt.Println()
	return ok
}

func sortedKeys(m map[string]float64) []string {
	var ks []string
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func main() {
	flag.Parse()
	var ok bool
	switch {
	case *targetsArg != "":
		if *runArg == "" && *scaleArg == "" {
			die("-targets needs -run, -scale or both")
		}
		ok = checkTargets()
	case *baseArg != "" || *headArg != "":
		ok = compare()
	default:
		die("usage: gate -base a.json,… -head b.json,… | gate -targets targets.json [-run matrix.json] [-scale scale.json]")
	}
	if !ok {
		fmt.Println("\ngate: FAILED")
		os.Exit(1)
	}
	if inconclusive {
		fmt.Println("\ngate: inconclusive")
		os.Exit(3)
	}
	fmt.Println("\ngate: passed")
}
