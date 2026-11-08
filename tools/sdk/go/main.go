// The AWS SDK for Go v2 against `cosmostore serve` (M3 SDK matrix). Run by tools/sdk/go.sh, which starts the server
// and sets AWS_ENDPOINT_URL and the credentials. Prints one line per check; exit status 1 if any fails.
package main

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/s3/manager"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"
)

var failed bool

func check(name string, got, want any) {
	if fmt.Sprint(got) == fmt.Sprint(want) {
		fmt.Println("ok  ", name)
	} else {
		fmt.Printf("FAIL %s: expected [%v], got [%v]\n", name, want, got)
		failed = true
	}
}

func codeOf(err error) string {
	var api smithy.APIError
	if errors.As(err, &api) {
		return api.ErrorCode()
	}
	if err == nil {
		return "no error"
	}
	return err.Error()
}

func must[T any](v T, err error) T {
	if err != nil {
		fmt.Println("FAIL", err)
		os.Exit(1)
	}
	return v
}

func random(n int) []byte {
	b := make([]byte, n)
	rand.Read(b)
	return b
}

func main() {
	ctx := context.Background()
	endpoint := os.Getenv("AWS_ENDPOINT_URL")
	cfg := must(config.LoadDefaultConfig(ctx))
	client := func(pathStyle bool) *s3.Client {
		return s3.NewFromConfig(cfg, func(o *s3.Options) {
			o.UsePathStyle = pathStyle
			if !pathStyle {
				o.BaseEndpoint = aws.String(strings.Replace(endpoint, "127.0.0.1", "localhost", 1))
			}
		})
	}
	c := client(true)
	b := aws.String("go-sdk-test")
	must(c.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: b}))
	_, err := c.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: b})
	check("create twice", codeOf(err), "BucketAlreadyOwnedByYou")

	body := random(300000)
	put := must(c.PutObject(ctx, &s3.PutObjectInput{Bucket: b, Key: aws.String("o/plain"), Body: bytes.NewReader(body),
		ContentType: aws.String("x/y"), Metadata: map[string]string{"k": "v"}}))
	check("put ETag", *put.ETag, fmt.Sprintf("\"%x\"", md5.Sum(body)))
	for _, algo := range []types.ChecksumAlgorithm{types.ChecksumAlgorithmCrc32, types.ChecksumAlgorithmCrc32c,
		types.ChecksumAlgorithmSha256, types.ChecksumAlgorithmCrc64nvme} {
		key := aws.String("o/" + string(algo))
		_, err := c.PutObject(ctx, &s3.PutObjectInput{Bucket: b, Key: key, Body: bytes.NewReader(body), ChecksumAlgorithm: algo})
		check("put with "+string(algo), err, nil)
	}
	got := must(c.GetObject(ctx, &s3.GetObjectInput{Bucket: b, Key: aws.String("o/plain")}))
	data := must(io.ReadAll(got.Body))
	check("get", bytes.Equal(data, body), true)
	check("content type and metadata", *got.ContentType+" "+got.Metadata["k"], "x/y v")
	ranged := must(c.GetObject(ctx, &s3.GetObjectInput{Bucket: b, Key: aws.String("o/plain"), Range: aws.String("bytes=5-9")}))
	check("range", bytes.Equal(must(io.ReadAll(ranged.Body)), body[5:10]), true)
	_, err = c.GetObject(ctx, &s3.GetObjectInput{Bucket: b, Key: aws.String("nope")})
	var nsk *types.NoSuchKey
	check("NoSuchKey type", errors.As(err, &nsk), true)
	_, err = c.HeadObject(ctx, &s3.HeadObjectInput{Bucket: b, Key: aws.String("nope")})
	var nf *types.NotFound
	check("head NotFound type", errors.As(err, &nf), true)

	for i := 0; i < 23; i++ {
		must(c.PutObject(ctx, &s3.PutObjectInput{Bucket: b, Key: aws.String(fmt.Sprintf("l/%02d", i)), Body: strings.NewReader("")}))
	}
	n := 0
	pages := s3.NewListObjectsV2Paginator(c, &s3.ListObjectsV2Input{Bucket: b, Prefix: aws.String("l/"), MaxKeys: aws.Int32(5)})
	for pages.HasMorePages() {
		n += len(must(pages.NextPage(ctx)).Contents)
	}
	check("list paginator", n, 23)

	big := random(13 << 20)
	up := manager.NewUploader(c, func(u *manager.Uploader) { u.PartSize = 5 << 20 })
	must(up.Upload(ctx, &s3.PutObjectInput{Bucket: b, Key: aws.String("m/big"), Body: bytes.NewReader(big)}))
	head := must(c.HeadObject(ctx, &s3.HeadObjectInput{Bucket: b, Key: aws.String("m/big")}))
	check("multipart ETag", strings.HasSuffix(*head.ETag, "-3\""), true)
	buf := manager.NewWriteAtBuffer(nil)
	down := manager.NewDownloader(c, func(d *manager.Downloader) { d.PartSize = 5 << 20 })
	must(down.Download(ctx, buf, &s3.GetObjectInput{Bucket: b, Key: aws.String("m/big")}))
	check("downloader", bytes.Equal(buf.Bytes(), big), true)
	must(c.CopyObject(ctx, &s3.CopyObjectInput{Bucket: b, Key: aws.String("o/copy"), CopySource: aws.String("go-sdk-test/o/plain")}))
	copied := must(c.GetObject(ctx, &s3.GetObjectInput{Bucket: b, Key: aws.String("o/copy")}))
	check("copy", bytes.Equal(must(io.ReadAll(copied.Body)), body), true)

	presign := s3.NewPresignClient(c)
	req := must(presign.PresignGetObject(ctx, &s3.GetObjectInput{Bucket: b, Key: aws.String("o/plain")}))
	resp := must(http.Get(req.URL))
	check("presigned GET", bytes.Equal(must(io.ReadAll(resp.Body)), body), true)
	preq := must(presign.PresignPutObject(ctx, &s3.PutObjectInput{Bucket: b, Key: aws.String("p/put")}))
	hreq := must(http.NewRequest("PUT", preq.URL, strings.NewReader("presigned")))
	check("presigned PUT", must(http.DefaultClient.Do(hreq)).StatusCode, 200)

	v := client(false)
	must(v.PutObject(ctx, &s3.PutObjectInput{Bucket: b, Key: aws.String("v/hosted"), Body: strings.NewReader("virtual")}))
	vg := must(v.GetObject(ctx, &s3.GetObjectInput{Bucket: b, Key: aws.String("v/hosted")}))
	check("virtual-host", string(must(io.ReadAll(vg.Body))), "virtual")

	var ids []types.ObjectIdentifier
	list := s3.NewListObjectsV2Paginator(c, &s3.ListObjectsV2Input{Bucket: b})
	for list.HasMorePages() {
		for _, o := range must(list.NextPage(ctx)).Contents {
			ids = append(ids, types.ObjectIdentifier{Key: o.Key})
		}
	}
	del := must(c.DeleteObjects(ctx, &s3.DeleteObjectsInput{Bucket: b, Delete: &types.Delete{Objects: ids}}))
	check("delete objects", len(del.Deleted), len(ids))
	must(c.DeleteBucket(ctx, &s3.DeleteBucketInput{Bucket: b}))
	_, err = c.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: b})
	check("bucket deleted", errors.As(err, &nf), true)
	if failed {
		os.Exit(1)
	}
}
