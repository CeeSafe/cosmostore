// M7 (ADR-0072 to ADR-0077) through the AWS SDK for Go v2: each item's configuration calls and what each does.
// common.sh starts serve with access logs every 2 s, a 3 s inventory day, websites under web.localhost and a role
// "reader" of sdk-m7.
package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/aws-sdk-go-v2/service/s3control"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	ststypes "github.com/aws/aws-sdk-go-v2/service/sts/types"
)

const account = "000000000000"

// until calls fn every quarter second for up to seconds, until it is true.
func until(seconds int, fn func() bool) bool {
	end := time.Now().Add(time.Duration(seconds) * time.Second)
	for time.Now().Before(end) {
		if fn() {
			return true
		}
		time.Sleep(250 * time.Millisecond)
	}
	return false
}

func keysUnder(ctx context.Context, c *s3.Client, bucket, prefix string) []string {
	var keys []string
	out, err := c.ListObjectsV2(ctx, &s3.ListObjectsV2Input{Bucket: aws.String(bucket), Prefix: aws.String(prefix)})
	if err != nil {
		return nil
	}
	for _, o := range out.Contents {
		keys = append(keys, *o.Key)
	}
	return keys
}

func read(ctx context.Context, c *s3.Client, bucket, key string) string {
	out, err := c.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(bucket), Key: aws.String(key)})
	if err != nil {
		return codeOf(err)
	}
	return string(must(io.ReadAll(out.Body)))
}

func m7(ctx context.Context, cfg aws.Config, endpoint string, c *s3.Client, client func(bool) *s3.Client) {
	m, logs := "sdk-m7", "sdk-m7-logs"
	for _, b := range []string{m, logs} {
		must(c.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: aws.String(b)}))
	}
	put := func(bucket, key, body string) {
		must(c.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String(key), Body: strings.NewReader(body),
			ContentType: aws.String("text/html")}))
	}
	put(m, "index.html", "the index")
	put(m, "error.html", "the error page")

	// Access logs (ADR-0072).
	must(c.PutBucketLogging(ctx, &s3.PutBucketLoggingInput{Bucket: aws.String(m), BucketLoggingStatus: &types.BucketLoggingStatus{
		LoggingEnabled: &types.LoggingEnabled{TargetBucket: aws.String(logs), TargetPrefix: aws.String("access/")}}}))
	lg := must(c.GetBucketLogging(ctx, &s3.GetBucketLoggingInput{Bucket: aws.String(m)}))
	check("GetBucketLogging", *lg.LoggingEnabled.TargetBucket+" "+*lg.LoggingEnabled.TargetPrefix, logs+" access/")
	_, err := c.PutBucketLogging(ctx, &s3.PutBucketLoggingInput{Bucket: aws.String(m), BucketLoggingStatus: &types.BucketLoggingStatus{
		LoggingEnabled: &types.LoggingEnabled{TargetBucket: aws.String("sdk-nowhere"), TargetPrefix: aws.String("x/")}}})
	check("logging to a bucket that is not there", codeOf(err), "InvalidTargetBucketForLogging")
	put(m, "logged.txt", "logged")
	check("the PUT's line in a log object", until(15, func() bool {
		for _, k := range keysUnder(ctx, c, logs, "access/") {
			if strings.Contains(read(ctx, c, logs, k), "REST.PUT.OBJECT logged.txt") {
				return true
			}
		}
		return false
	}), true)
	must(c.PutBucketLogging(ctx, &s3.PutBucketLoggingInput{Bucket: aws.String(m), BucketLoggingStatus: &types.BucketLoggingStatus{}}))
	lg = must(c.GetBucketLogging(ctx, &s3.GetBucketLoggingInput{Bucket: aws.String(m)}))
	check("logging off", lg.LoggingEnabled == nil, true)

	// Website hosting (ADR-0073), through <bucket>.web.localhost, with a policy that lets anyone read.
	must(c.PutBucketWebsite(ctx, &s3.PutBucketWebsiteInput{Bucket: aws.String(m), WebsiteConfiguration: &types.WebsiteConfiguration{
		IndexDocument: &types.IndexDocument{Suffix: aws.String("index.html")}, ErrorDocument: &types.ErrorDocument{Key: aws.String("error.html")}}}))
	ws := must(c.GetBucketWebsite(ctx, &s3.GetBucketWebsiteInput{Bucket: aws.String(m)}))
	check("GetBucketWebsite", *ws.IndexDocument.Suffix+" "+*ws.ErrorDocument.Key, "index.html error.html")
	must(c.PutBucketPolicy(ctx, &s3.PutBucketPolicyInput{Bucket: aws.String(m), Policy: aws.String(
		`{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::sdk-m7/*"}]}`)}))
	port := endpoint[strings.LastIndex(endpoint, ":")+1:]
	site := func(path string) string {
		req := must(http.NewRequest("GET", endpoint+path, nil))
		req.Host = m + ".web.localhost:" + port
		resp := must(http.DefaultClient.Do(req))
		defer resp.Body.Close()
		return fmt.Sprintf("%d %s", resp.StatusCode, must(io.ReadAll(resp.Body)))
	}
	check("the site's index", site("/"), "200 the index")
	check("the site's error document", site("/no-such-page"), "404 the error page")
	must(c.DeleteBucketWebsite(ctx, &s3.DeleteBucketWebsiteInput{Bucket: aws.String(m)}))
	_, err = c.GetBucketWebsite(ctx, &s3.GetBucketWebsiteInput{Bucket: aws.String(m)})
	check("the website deleted", codeOf(err), "NoSuchWebsiteConfiguration")
	must(c.DeleteBucketPolicy(ctx, &s3.DeleteBucketPolicyInput{Bucket: aws.String(m)}))

	// Inventory (ADR-0074): a daily CSV report into the logs bucket; a day is 3 s here.
	inventory := func(id string, dest types.InventoryS3BucketDestination) *s3.PutBucketInventoryConfigurationInput {
		return &s3.PutBucketInventoryConfigurationInput{Bucket: aws.String(m), Id: aws.String(id), InventoryConfiguration: &types.InventoryConfiguration{
			Id: aws.String(id), IsEnabled: aws.Bool(true), IncludedObjectVersions: types.InventoryIncludedObjectVersionsCurrent,
			Schedule:    &types.InventorySchedule{Frequency: types.InventoryFrequencyDaily},
			Destination: &types.InventoryDestination{S3BucketDestination: &dest}}}
	}
	dest := types.InventoryS3BucketDestination{Bucket: aws.String("arn:aws:s3:::" + logs), Format: types.InventoryFormatCsv, Prefix: aws.String("inv")}
	must(c.PutBucketInventoryConfiguration(ctx, inventory("daily", dest)))
	inv := must(c.GetBucketInventoryConfiguration(ctx, &s3.GetBucketInventoryConfigurationInput{Bucket: aws.String(m), Id: aws.String("daily")}))
	check("GetBucketInventoryConfiguration", fmt.Sprint(*inv.InventoryConfiguration.Id, " ", *inv.InventoryConfiguration.IsEnabled, " ",
		inv.InventoryConfiguration.Schedule.Frequency, " ", *inv.InventoryConfiguration.Destination.S3BucketDestination.Bucket), "daily true Daily arn:aws:s3:::"+logs)
	list := must(c.ListBucketInventoryConfigurations(ctx, &s3.ListBucketInventoryConfigurationsInput{Bucket: aws.String(m)}))
	check("ListBucketInventoryConfigurations", len(list.InventoryConfigurationList), 1)
	other := dest
	other.AccountId = aws.String("111122223333")
	_, err = c.PutBucketInventoryConfiguration(ctx, inventory("acct", other))
	check("an account id is not done, not dropped", codeOf(err), "NotImplemented")
	var manifest string
	until(20, func() bool {
		for _, k := range keysUnder(ctx, c, logs, "inv/") {
			if strings.HasSuffix(k, "manifest.json") {
				manifest = k
				return true
			}
		}
		return false
	})
	check("a report's manifest", manifest != "", true)
	if manifest != "" {
		var doc struct {
			Files []struct{ Key string } `json:"files"`
		}
		must(0, json.Unmarshal([]byte(read(ctx, c, logs, manifest)), &doc))
		zr := must(gzip.NewReader(bytes.NewReader([]byte(read(ctx, c, logs, doc.Files[0].Key)))))
		rows := must(csv.NewReader(zr).ReadAll())
		var keys []string
		for _, r := range rows {
			keys = append(keys, r[1])
		}
		sort.Strings(keys)
		check("its CSV has every object", strings.Join(keys, " "), "error.html index.html logged.txt")
	}
	must(c.DeleteBucketInventoryConfiguration(ctx, &s3.DeleteBucketInventoryConfigurationInput{Bucket: aws.String(m), Id: aws.String("daily")}))
	_, err = c.GetBucketInventoryConfiguration(ctx, &s3.GetBucketInventoryConfigurationInput{Bucket: aws.String(m), Id: aws.String("daily")})
	check("the inventory deleted", codeOf(err), "NoSuchConfiguration")

	// STS (ADR-0075): a session token, and the role "reader", sign S3 requests.
	st := sts.NewFromConfig(cfg)
	as := func(c *ststypes.Credentials) *s3.Client {
		return s3.NewFromConfig(cfg, func(o *s3.Options) {
			o.UsePathStyle = true
			o.Credentials = credentials.NewStaticCredentialsProvider(*c.AccessKeyId, *c.SecretAccessKey, *c.SessionToken)
		})
	}
	session := must(st.GetSessionToken(ctx, &sts.GetSessionTokenInput{DurationSeconds: aws.Int32(900)})).Credentials
	check("GetSessionToken gives an ASIA key", (*session.AccessKeyId)[:4], "ASIA")
	check("the session reads", read(ctx, as(session), m, "logged.txt"), "logged")
	role := must(st.AssumeRole(ctx, &sts.AssumeRoleInput{RoleArn: aws.String("arn:aws:iam::" + account + ":role/reader"),
		RoleSessionName: aws.String("go")})).Credentials
	reader := as(role)
	check("the role reads", read(ctx, reader, m, "logged.txt"), "logged")
	_, err = reader.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String(m), Key: aws.String("no"), Body: strings.NewReader("no")})
	check("the role does not write", codeOf(err), "AccessDenied")
	_, err = reader.ListObjectsV2(ctx, &s3.ListObjectsV2Input{Bucket: aws.String(logs)})
	check("nor read another bucket", codeOf(err), "AccessDenied")
	_, err = st.AssumeRole(ctx, &sts.AssumeRoleInput{RoleArn: aws.String("arn:aws:iam::" + account + ":role/reader"),
		RoleSessionName: aws.String("arns"), PolicyArns: []ststypes.PolicyDescriptorType{{Arn: aws.String("arn:aws:iam::aws:policy/ReadOnlyAccess")}}})
	check("policy ARNs are not done, not dropped", codeOf(err), "NotImplemented")

	// Access Points (ADR-0076): S3 Control puts the account in the host, so it goes to localhost
	// (`<account>.localhost`); a request by ARN goes to `<name>-<account>.localhost`.
	ctl := s3control.NewFromConfig(cfg, func(o *s3control.Options) {
		o.BaseEndpoint = aws.String(strings.Replace(endpoint, "127.0.0.1", "localhost", 1))
	})
	made := must(ctl.CreateAccessPoint(ctx, &s3control.CreateAccessPointInput{AccountId: aws.String(account), Name: aws.String("sdk-ap"), Bucket: aws.String(m)}))
	alias := aws.ToString(made.Alias)
	check("CreateAccessPoint gives an alias", strings.HasSuffix(alias, "-s3alias"), true)
	ap := must(ctl.GetAccessPoint(ctx, &s3control.GetAccessPointInput{AccountId: aws.String(account), Name: aws.String("sdk-ap")}))
	check("GetAccessPoint", *ap.Bucket+" "+string(ap.NetworkOrigin), m+" Internet")
	aps := must(ctl.ListAccessPoints(ctx, &s3control.ListAccessPointsInput{AccountId: aws.String(account), Bucket: aws.String(m)}))
	check("ListAccessPoints", len(aps.AccessPointList), 1)
	_, err = ctl.CreateAccessPoint(ctx, &s3control.CreateAccessPointInput{AccountId: aws.String(account), Name: aws.String("sdk-ap"), Bucket: aws.String(m)})
	check("a name twice", codeOf(err), "AccessPointAlreadyOwnedByYou")
	must(c.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String(alias), Key: aws.String("ap/door.txt"), Body: strings.NewReader("through a door")}))
	check("a write by its alias lands in its bucket", read(ctx, c, m, "ap/door.txt"), "through a door")
	check("a read by its ARN", read(ctx, client(false), "arn:aws:s3:us-east-1:"+account+":accesspoint/sdk-ap", "ap/door.txt"), "through a door")
	must(ctl.DeleteAccessPoint(ctx, &s3control.DeleteAccessPointInput{AccountId: aws.String(account), Name: aws.String("sdk-ap")}))
	_, err = ctl.GetAccessPoint(ctx, &s3control.GetAccessPointInput{AccountId: aws.String(account), Name: aws.String("sdk-ap")})
	check("the access point deleted", codeOf(err), "NoSuchAccessPoint")

	// Replication (ADR-0077): a new version copied to another bucket with its version id and ETag.
	rs, rd := "sdk-rsrc", "sdk-rdst"
	for _, b := range []string{rs, rd} {
		must(c.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: aws.String(b)}))
		must(c.PutBucketVersioning(ctx, &s3.PutBucketVersioningInput{Bucket: aws.String(b),
			VersioningConfiguration: &types.VersioningConfiguration{Status: types.BucketVersioningStatusEnabled}}))
	}
	rule := func(id string) types.ReplicationRule {
		return types.ReplicationRule{ID: aws.String(id), Priority: aws.Int32(1), Status: types.ReplicationRuleStatusEnabled,
			Filter:                  &types.ReplicationRuleFilter{Prefix: aws.String("")},
			DeleteMarkerReplication: &types.DeleteMarkerReplication{Status: types.DeleteMarkerReplicationStatusEnabled},
			Destination:             &types.Destination{Bucket: aws.String("arn:aws:s3:::" + rd)}}
	}
	replication := func(rules ...types.ReplicationRule) *s3.PutBucketReplicationInput {
		return &s3.PutBucketReplicationInput{Bucket: aws.String(rs), ReplicationConfiguration: &types.ReplicationConfiguration{
			Role: aws.String("arn:aws:iam::" + account + ":role/r"), Rules: rules}}
	}
	_, err = c.PutBucketReplication(ctx, replication(rule("all"), rule("again")))
	check("one priority twice", codeOf(err), "InvalidArgument")
	must(c.PutBucketReplication(ctx, replication(rule("all"))))
	rp := must(c.GetBucketReplication(ctx, &s3.GetBucketReplicationInput{Bucket: aws.String(rs)}))
	check("GetBucketReplication", *rp.ReplicationConfiguration.Rules[0].Destination.Bucket, "arn:aws:s3:::"+rd)
	src := must(c.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String(rs), Key: aws.String("r/one.txt"), Body: strings.NewReader("replicate me")}))
	check("replicated", until(15, func() bool {
		h, err := c.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(rs), Key: aws.String("r/one.txt")})
		return err == nil && h.ReplicationStatus == types.ReplicationStatusCompleted
	}), true)
	replica := must(c.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(rd), Key: aws.String("r/one.txt")}))
	check("the replica keeps its version id and ETag", *replica.VersionId+" "+*replica.ETag, *src.VersionId+" "+*src.ETag)
	check("and is a replica", replica.ReplicationStatus, types.ReplicationStatusReplica)
	must(c.DeleteBucketReplication(ctx, &s3.DeleteBucketReplicationInput{Bucket: aws.String(rs)}))
	_, err = c.GetBucketReplication(ctx, &s3.GetBucketReplicationInput{Bucket: aws.String(rs)})
	check("the replication deleted", codeOf(err), "ReplicationConfigurationNotFoundError")
}
