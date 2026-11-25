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
	// Maintenance (ADR-0086): a table bucket's configuration put and read back; compaction is not done.
	_, err = t.PutTableBucketMaintenanceConfiguration(ctx, &s3tables.PutTableBucketMaintenanceConfigurationInput{
		TableBucketARN: arn, Type: tabletypes.TableBucketMaintenanceTypeIcebergUnreferencedFileRemoval,
		Value: &tabletypes.TableBucketMaintenanceConfigurationValue{Status: tabletypes.MaintenanceStatusEnabled,
			Settings: &tabletypes.TableBucketMaintenanceSettingsMemberIcebergUnreferencedFileRemoval{
				Value: tabletypes.IcebergUnreferencedFileRemovalSettings{UnreferencedDays: aws.Int32(4), NonCurrentDays: aws.Int32(9)}}}})
	check("PutTableBucketMaintenanceConfiguration", codeOf(err), "no error")
	bm := must(t.GetTableBucketMaintenanceConfiguration(ctx, &s3tables.GetTableBucketMaintenanceConfigurationInput{TableBucketARN: arn}))
	days := int32(0)
	if s, ok := bm.Configuration["icebergUnreferencedFileRemoval"].Settings.(*tabletypes.TableBucketMaintenanceSettingsMemberIcebergUnreferencedFileRemoval); ok {
		days = aws.ToInt32(s.Value.UnreferencedDays)
	}
	check("GetTableBucketMaintenanceConfiguration", days, int32(4))
	tm := must(t.GetTableMaintenanceConfiguration(ctx, &s3tables.GetTableMaintenanceConfigurationInput{TableBucketARN: arn,
		Namespace: aws.String("sales"), Name: aws.String("orders2")}))
	check("GetTableMaintenanceConfiguration: compaction on by default", tm.Configuration["icebergCompaction"].Status, tabletypes.MaintenanceStatusEnabled)
	js := must(t.GetTableMaintenanceJobStatus(ctx, &s3tables.GetTableMaintenanceJobStatusInput{TableBucketARN: arn,
		Namespace: aws.String("sales"), Name: aws.String("orders2")}))
	check("GetTableMaintenanceJobStatus", js.Status["icebergCompaction"].Status, tabletypes.JobStatusNotYetRun)
	must(t.DeleteTable(ctx, &s3tables.DeleteTableInput{TableBucketARN: arn, Namespace: aws.String("sales"), Name: aws.String("orders2")}))
	must(t.DeleteNamespace(ctx, &s3tables.DeleteNamespaceInput{TableBucketARN: arn, Namespace: aws.String("sales")}))
	must(t.DeleteTableBucket(ctx, &s3tables.DeleteTableBucketInput{TableBucketARN: arn}))
	check("DeleteTableBucket", len(must(t.ListTableBuckets(ctx, &s3tables.ListTableBucketsInput{})).TableBuckets), 0)
	tablesConfig(ctx, t)
}

// Tags, storage class and encryption (ADR-0126): a table bucket's, set at its create and changed after; a table takes
// its bucket's storage class and encryption at its own create and keeps them.
func tablesConfig(ctx context.Context, t *s3tables.Client) {
	made, err := t.CreateTableBucket(ctx, &s3tables.CreateTableBucketInput{Name: aws.String("sdk-go-config"),
		Tags:                      map[string]string{"team": "data"},
		StorageClassConfiguration: &tabletypes.StorageClassConfiguration{StorageClass: tabletypes.StorageClassIntelligentTiering},
		EncryptionConfiguration:   &tabletypes.EncryptionConfiguration{SseAlgorithm: tabletypes.SSEAlgorithmAes256}})
	check("CreateTableBucket with tags, a storage class and encryption", codeOf(err), "no error")
	if err != nil {
		return
	}
	arn := made.Arn
	tags := func(resource *string) any {
		got, err := t.ListTagsForResource(ctx, &s3tables.ListTagsForResourceInput{ResourceArn: resource})
		if err != nil {
			return codeOf(err)
		}
		return got.Tags
	}
	bucketClass := func() any {
		got, err := t.GetTableBucketStorageClass(ctx, &s3tables.GetTableBucketStorageClassInput{TableBucketARN: arn})
		if err != nil || got.StorageClassConfiguration == nil {
			return codeOf(err)
		}
		return got.StorageClassConfiguration.StorageClass
	}
	tableClass := func() any {
		got, err := t.GetTableStorageClass(ctx, &s3tables.GetTableStorageClassInput{TableBucketARN: arn,
			Namespace: aws.String("ns"), Name: aws.String("t")})
		if err != nil || got.StorageClassConfiguration == nil {
			return codeOf(err)
		}
		return got.StorageClassConfiguration.StorageClass
	}
	tableSse := func() any {
		got, err := t.GetTableEncryption(ctx, &s3tables.GetTableEncryptionInput{TableBucketARN: arn,
			Namespace: aws.String("ns"), Name: aws.String("t")})
		if err != nil || got.EncryptionConfiguration == nil {
			return codeOf(err)
		}
		return got.EncryptionConfiguration.SseAlgorithm
	}
	check("ListTagsForResource: its create's tags", tags(arn), map[string]string{"team": "data"})
	_, err = t.TagResource(ctx, &s3tables.TagResourceInput{ResourceArn: arn, Tags: map[string]string{"env": "test"}})
	check("TagResource", codeOf(err), "no error")
	_, err = t.UntagResource(ctx, &s3tables.UntagResourceInput{ResourceArn: arn, TagKeys: []string{"team"}})
	check("UntagResource", codeOf(err), "no error")
	check("ListTagsForResource: one added, one removed", tags(arn), map[string]string{"env": "test"})
	check("GetTableBucketStorageClass", bucketClass(), tabletypes.StorageClassIntelligentTiering)
	sse, err := t.GetTableBucketEncryption(ctx, &s3tables.GetTableBucketEncryptionInput{TableBucketARN: arn})
	if err == nil && sse.EncryptionConfiguration != nil {
		check("GetTableBucketEncryption", sse.EncryptionConfiguration.SseAlgorithm, tabletypes.SSEAlgorithmAes256)
	} else {
		check("GetTableBucketEncryption", codeOf(err), tabletypes.SSEAlgorithmAes256)
	}
	must(t.CreateNamespace(ctx, &s3tables.CreateNamespaceInput{TableBucketARN: arn, Namespace: []string{"ns"}}))
	table := must(t.CreateTable(ctx, &s3tables.CreateTableInput{TableBucketARN: arn, Namespace: aws.String("ns"),
		Name: aws.String("t"), Format: tabletypes.OpenTableFormatIceberg}))
	check("GetTableStorageClass: its bucket's", tableClass(), tabletypes.StorageClassIntelligentTiering)
	check("GetTableEncryption: its bucket's", tableSse(), tabletypes.SSEAlgorithmAes256)
	check("ListTagsForResource: a table's, none", tags(table.TableARN), map[string]string{})
	_, err = t.PutTableBucketStorageClass(ctx, &s3tables.PutTableBucketStorageClassInput{TableBucketARN: arn,
		StorageClassConfiguration: &tabletypes.StorageClassConfiguration{StorageClass: tabletypes.StorageClassStandard}})
	check("PutTableBucketStorageClass", codeOf(err), "no error")
	check("GetTableBucketStorageClass: changed", bucketClass(), tabletypes.StorageClassStandard)
	check("GetTableStorageClass: a table keeps its create's", tableClass(), tabletypes.StorageClassIntelligentTiering)
	_, err = t.DeleteTableBucketEncryption(ctx, &s3tables.DeleteTableBucketEncryptionInput{TableBucketARN: arn})
	check("DeleteTableBucketEncryption", codeOf(err), "no error")
	_, err = t.GetTableBucketEncryption(ctx, &s3tables.GetTableBucketEncryptionInput{TableBucketARN: arn})
	check("GetTableBucketEncryption: none after", err != nil, true)
	check("GetTableEncryption: a table keeps its create's", tableSse(), tabletypes.SSEAlgorithmAes256)
	must(t.DeleteTable(ctx, &s3tables.DeleteTableInput{TableBucketARN: arn, Namespace: aws.String("ns"), Name: aws.String("t")}))
	must(t.DeleteNamespace(ctx, &s3tables.DeleteNamespaceInput{TableBucketARN: arn, Namespace: aws.String("ns")}))
	must(t.DeleteTableBucket(ctx, &s3tables.DeleteTableBucketInput{TableBucketARN: arn}))
	check("DeleteTableBucket: the configured one", len(must(t.ListTableBuckets(ctx, &s3tables.ListTableBucketsInput{})).TableBuckets), 0)
}
