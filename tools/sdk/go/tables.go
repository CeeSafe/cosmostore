// S3 Tables (ADR-0083) through the AWS SDK for Go v2: table buckets, namespaces and tables, and the metadata
// location's compare-and-set on the versionToken.
package main

import (
	"bytes"
	"context"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3tables"
	tabletypes "github.com/aws/aws-sdk-go-v2/service/s3tables/types"
)

func tables(ctx context.Context, cfg aws.Config) {
	t := s3tables.NewFromConfig(cfg)
	s := s3.NewFromConfig(cfg, func(o *s3.Options) { o.UsePathStyle = true })
	made, err := t.CreateTableBucket(ctx, &s3tables.CreateTableBucketInput{Name: aws.String("sdk-go-tables")})
	check("CreateTableBucket", codeOf(err), "no error")
	if err != nil {
		return
	}
	arn := made.Arn
	check("its ARN", aws.ToString(arn), "arn:aws:s3tables:us-east-1:"+account+":bucket/sdk-go-tables")
	listed := must(t.ListTableBuckets(ctx, &s3tables.ListTableBucketsInput{}))
	check("ListTableBuckets", len(listed.TableBuckets) == 1 && aws.ToString(listed.TableBuckets[0].Name) == "sdk-go-tables", true)
	must(t.CreateNamespace(ctx, &s3tables.CreateNamespaceInput{TableBucketARN: arn, Namespace: []string{"sales"}}))
	table := must(t.CreateTable(ctx, &s3tables.CreateTableInput{TableBucketARN: arn, Namespace: aws.String("sales"),
		Name: aws.String("orders"), Format: tabletypes.OpenTableFormatIceberg}))
	got := must(t.GetTable(ctx, &s3tables.GetTableInput{TableArn: table.TableARN}))
	check("GetTable by its ARN", aws.ToString(got.Name), "orders")
	wh := aws.ToString(got.WarehouseLocation)
	parts := strings.SplitN(strings.TrimPrefix(wh, "s3://"), "/", 2)
	must(s.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String(parts[0]), Key: aws.String(parts[1] + "/metadata/00001-g.metadata.json"),
		Body: bytes.NewReader([]byte("{}"))}))
	moved, err := t.UpdateTableMetadataLocation(ctx, &s3tables.UpdateTableMetadataLocationInput{TableBucketARN: arn,
		Namespace: aws.String("sales"), Name: aws.String("orders"), VersionToken: got.VersionToken,
		MetadataLocation: aws.String(wh + "/metadata/00001-g.metadata.json")})
	check("UpdateTableMetadataLocation", codeOf(err), "no error")
	_, err = t.UpdateTableMetadataLocation(ctx, &s3tables.UpdateTableMetadataLocationInput{TableBucketARN: arn,
		Namespace: aws.String("sales"), Name: aws.String("orders"), VersionToken: got.VersionToken,
		MetadataLocation: aws.String(wh + "/metadata/00002-g.metadata.json")})
	check("a stale versionToken", codeOf(err), "ConflictException")
	if moved != nil {
		check("its token moved on", aws.ToString(moved.VersionToken) != aws.ToString(got.VersionToken), true)
	}
	must(t.RenameTable(ctx, &s3tables.RenameTableInput{TableBucketARN: arn, Namespace: aws.String("sales"),
		Name: aws.String("orders"), NewName: aws.String("orders2")}))
	names := must(t.ListTables(ctx, &s3tables.ListTablesInput{TableBucketARN: arn}))
	check("RenameTable", len(names.Tables) == 1 && aws.ToString(names.Tables[0].Name) == "orders2", true)
	must(t.DeleteTable(ctx, &s3tables.DeleteTableInput{TableBucketARN: arn, Namespace: aws.String("sales"), Name: aws.String("orders2")}))
	must(t.DeleteNamespace(ctx, &s3tables.DeleteNamespaceInput{TableBucketARN: arn, Namespace: aws.String("sales")}))
	must(t.DeleteTableBucket(ctx, &s3tables.DeleteTableBucketInput{TableBucketARN: arn}))
	check("DeleteTableBucket", len(must(t.ListTableBuckets(ctx, &s3tables.ListTableBucketsInput{})).TableBuckets), 0)
}
