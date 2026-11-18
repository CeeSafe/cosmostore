// Directory buckets (ADR-0080) through the AWS SDK for Go v2: made, listed, written and read with the SDK's sessions
// (CreateSession) and with them off. common.sh starts serve with the zone local-az1.
package main

import (
	"bytes"
	"context"
	"crypto/md5"
	"fmt"
	"io"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/s3/manager"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

func directory(ctx context.Context, cfg aws.Config) {
	const dir = "sdk--local-az1--x-s3"
	// ListDirectoryBuckets takes no session; with sessions on against a custom endpoint the SDK asks for one anyway,
	// without a bucket, and fails before sending ("bucket name is missing"): it is listed with sessions off.
	lister := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.UsePathStyle = true
		o.DisableS3ExpressSessionAuth = aws.Bool(true)
	})
	for _, sessions := range []bool{true, false} {
		how := " (sessions)"
		if !sessions {
			how = " (sessions off)"
		}
		d := s3.NewFromConfig(cfg, func(o *s3.Options) {
			o.UsePathStyle = true
			if !sessions {
				o.DisableS3ExpressSessionAuth = aws.Bool(true)
			}
		})
		made, err := d.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: aws.String(dir), CreateBucketConfiguration: &types.CreateBucketConfiguration{
			Location: &types.LocationInfo{Type: types.LocationTypeAvailabilityZone, Name: aws.String("local-az1")},
			Bucket:   &types.BucketInfo{DataRedundancy: types.DataRedundancySingleAvailabilityZone, Type: types.BucketTypeDirectory}}})
		check("create a directory bucket"+how, codeOf(err), "no error")
		if err != nil {
			continue
		}
		check("its ARN"+how, strings.HasSuffix(aws.ToString(made.BucketArn), ":bucket/"+dir), true)
		listed := must(lister.ListDirectoryBuckets(ctx, &s3.ListDirectoryBucketsInput{}))
		check("ListDirectoryBuckets"+how, len(listed.Buckets) == 1 && aws.ToString(listed.Buckets[0].Name) == dir, true)
		body := []byte("in a directory")
		put := must(d.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String(dir), Key: aws.String("a/b.txt"), Body: bytes.NewReader(body)}))
		check("an ETag that is not the MD5"+how, *put.ETag != fmt.Sprintf("\"%x\"", md5.Sum(body)), true)
		got := must(d.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(dir), Key: aws.String("a/b.txt"), IfMatch: put.ETag}))
		check("GET with If-Match"+how, string(must(io.ReadAll(got.Body))), string(body))
		page := must(d.ListObjectsV2(ctx, &s3.ListObjectsV2Input{Bucket: aws.String(dir), Prefix: aws.String("a/")}))
		check("listed"+how, len(page.Contents) == 1 && *page.Contents[0].Key == "a/b.txt", true)
		up := manager.NewUploader(d, func(u *manager.Uploader) { u.PartSize = 5 << 20 })
		must(up.Upload(ctx, &s3.PutObjectInput{Bucket: aws.String(dir), Key: aws.String("big/m.bin"), Body: bytes.NewReader(random(12 << 20))}))
		head := must(d.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(dir), Key: aws.String("big/m.bin")}))
		check("a multipart ETag without -N"+how, strings.Contains(*head.ETag, "-"), false)
		_, err = d.PutBucketVersioning(ctx, &s3.PutBucketVersioningInput{Bucket: aws.String(dir),
			VersioningConfiguration: &types.VersioningConfiguration{Status: types.BucketVersioningStatusEnabled}})
		check("no versioning"+how, codeOf(err), "NotImplemented")
		for _, k := range []string{"a/b.txt", "big/m.bin"} {
			must(d.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: aws.String(dir), Key: aws.String(k)}))
		}
		must(d.DeleteBucket(ctx, &s3.DeleteBucketInput{Bucket: aws.String(dir)}))
		check("deleted"+how, len(must(lister.ListDirectoryBuckets(ctx, &s3.ListDirectoryBucketsInput{})).Buckets), 0)
	}
}
