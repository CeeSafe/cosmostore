// Users (ADR-0088) through the AWS SDK for Go v2: a user's key reads what its identity policy allows, and nothing else.
package main

import (
	"bytes"
	"context"
	"io"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func users(ctx context.Context, cfg aws.Config) {
	account := s3.NewFromConfig(cfg, func(o *s3.Options) { o.UsePathStyle = true })
	b := aws.String("sdk-go-users")
	must(account.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: b}))
	must(account.PutObject(ctx, &s3.PutObjectInput{Bucket: b, Key: aws.String("a"), Body: bytes.NewReader([]byte("read me"))}))
	user := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.UsePathStyle = true
		o.Credentials = credentials.NewStaticCredentialsProvider("AKIASDKUSER000000001", "sdkuser/secret/0123456789abcdefgh", "")
	})
	got, err := user.GetObject(ctx, &s3.GetObjectInput{Bucket: b, Key: aws.String("a")})
	body := ""
	if err == nil {
		read, _ := io.ReadAll(got.Body)
		body = string(read)
	}
	check("a user reads", body, "read me")
	_, err = user.PutObject(ctx, &s3.PutObjectInput{Bucket: b, Key: aws.String("b"), Body: bytes.NewReader([]byte("x"))})
	check("a user writes nothing", codeOf(err), "AccessDenied")
	_, err = user.ListBuckets(ctx, &s3.ListBucketsInput{})
	check("nor lists every bucket", codeOf(err), "AccessDenied")
	must(account.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: b, Key: aws.String("a")}))
	must(account.DeleteBucket(ctx, &s3.DeleteBucketInput{Bucket: b}))
}
