// Access points of directory buckets (ADR-0082) through the AWS SDK for Go v2: made with a scope, requests through
// them with the SDK's sessions, and their own listing.
package main

import (
	"bytes"
	"context"
	"io"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/aws-sdk-go-v2/service/s3control"
	ctltypes "github.com/aws/aws-sdk-go-v2/service/s3control/types"
)

func directoryAccessPoints(ctx context.Context, cfg aws.Config, endpoint string) {
	const bucket, door = "sdk4--local-az1--x-s3", "sdkgo--local-az1--xa-s3"
	d := s3.NewFromConfig(cfg, func(o *s3.Options) { o.UsePathStyle = true })
	must(d.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: aws.String(bucket), CreateBucketConfiguration: &types.CreateBucketConfiguration{
		Location: &types.LocationInfo{Type: types.LocationTypeAvailabilityZone, Name: aws.String("local-az1")},
		Bucket:   &types.BucketInfo{DataRedundancy: types.DataRedundancySingleAvailabilityZone, Type: types.BucketTypeDirectory}}}))
	ctl := s3control.NewFromConfig(cfg, func(o *s3control.Options) {
		o.BaseEndpoint = aws.String(strings.Replace(endpoint, "127.0.0.1", "localhost", 1))
	})
	made, err := ctl.CreateAccessPoint(ctx, &s3control.CreateAccessPointInput{AccountId: aws.String(account), Name: aws.String(door),
		Bucket: aws.String(bucket), Scope: &ctltypes.Scope{Prefixes: []string{"pub/"},
			Permissions: []ctltypes.ScopePermission{ctltypes.ScopePermissionGetObject, ctltypes.ScopePermissionPutObject}}})
	check("directory access point: created", codeOf(err), "no error")
	if err != nil {
		return
	}
	check("directory access point: its alias is its name", aws.ToString(made.Alias), door)
	scope := must(ctl.GetAccessPointScope(ctx, &s3control.GetAccessPointScopeInput{AccountId: aws.String(account), Name: aws.String(door)}))
	check("GetAccessPointScope", len(scope.Scope.Permissions) == 2 && scope.Scope.Prefixes[0] == "pub/", true)
	listed := must(ctl.ListAccessPointsForDirectoryBuckets(ctx, &s3control.ListAccessPointsForDirectoryBucketsInput{
		AccountId: aws.String(account), DirectoryBucket: aws.String(bucket)}))
	check("ListAccessPointsForDirectoryBuckets", len(listed.AccessPointList) == 1 && aws.ToString(listed.AccessPointList[0].Name) == door, true)
	must(d.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String(door), Key: aws.String("pub/a.txt"), Body: bytes.NewReader([]byte("through"))}))
	got := must(d.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(door), Key: aws.String("pub/a.txt")}))
	check("a GET through it", string(must(io.ReadAll(got.Body))), "through")
	_, err = d.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(door), Key: aws.String("other/a.txt")})
	check("a key outside its scope", codeOf(err), "AccessDenied")
	_, err = d.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: aws.String(door), Key: aws.String("pub/a.txt")})
	check("a permission outside its scope", codeOf(err), "AccessDenied")
	must(ctl.DeleteAccessPoint(ctx, &s3control.DeleteAccessPointInput{AccountId: aws.String(account), Name: aws.String(door)}))
	must(d.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("pub/a.txt")}))
	must(d.DeleteBucket(ctx, &s3.DeleteBucketInput{Bucket: aws.String(bucket)}))
}
