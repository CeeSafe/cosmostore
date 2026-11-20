// The long tail (ADR-0090) through the AWS SDK for Go v2: storage classes recorded, or refused.
package main

import (
	"bytes"
	"context"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

func longTail(ctx context.Context, cfg aws.Config) {
	c := s3.NewFromConfig(cfg, func(o *s3.Options) { o.UsePathStyle = true })
	b := aws.String("sdk-go-tail")
	must(c.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: b}))
	must(c.PutObject(ctx, &s3.PutObjectInput{Bucket: b, Key: aws.String("ia"), Body: bytes.NewReader([]byte("x")),
		StorageClass: types.StorageClassStandardIa}))
	head := must(c.HeadObject(ctx, &s3.HeadObjectInput{Bucket: b, Key: aws.String("ia")}))
	check("a storage class recorded", string(head.StorageClass), "STANDARD_IA")
	_, err := c.PutObject(ctx, &s3.PutObjectInput{Bucket: b, Key: aws.String("g"), Body: bytes.NewReader([]byte("x")),
		StorageClass: types.StorageClassGlacier})
	// An archive class (ADR-0102): taken; its read InvalidObjectState until restored.
	check("an archive class taken", codeOf(err), "no error")
	_, err = c.GetObject(ctx, &s3.GetObjectInput{Bucket: b, Key: aws.String("g")})
	check("its read refused, not restored", codeOf(err), "InvalidObjectState")
	must(c.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: b, Key: aws.String("g")}))
	must(c.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: b, Key: aws.String("ia")}))
	must(c.DeleteBucket(ctx, &s3.DeleteBucketInput{Bucket: b}))
}
