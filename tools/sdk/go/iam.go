// The IAM API (ADR-0104) through the AWS SDK for Go v2: a user, its key and policy; the key signs within an upkeep
// round (10 s here); a role made with a trust policy and assumed; everything deleted, and the key refused after.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/url"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/sts"
)

// Polls fn every 250 ms until it is true or `seconds` pass.
func within(seconds int, fn func() bool) bool {
	end := time.Now().Add(time.Duration(seconds) * time.Second)
	for time.Now().Before(end) {
		if fn() {
			return true
		}
		time.Sleep(250 * time.Millisecond)
	}
	return false
}

// A policy document as IAM answers it: URL-encoded JSON.
func policyDoc(text *string) map[string]any {
	out := map[string]any{}
	if text == nil {
		return out
	}
	plain, err := url.QueryUnescape(*text)
	if err != nil {
		return out
	}
	_ = json.Unmarshal([]byte(plain), &out)
	return out
}

func iamChecks(ctx context.Context, cfg aws.Config) {
	account := s3.NewFromConfig(cfg, func(o *s3.Options) { o.UsePathStyle = true })
	b := aws.String("sdk-go-iam")
	must(account.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: b}))
	must(account.PutObject(ctx, &s3.PutObjectInput{Bucket: b, Key: aws.String("a"), Body: bytes.NewReader([]byte("read me"))}))
	im := iam.NewFromConfig(cfg)
	created := must(im.CreateUser(ctx, &iam.CreateUserInput{UserName: aws.String("go-dev")}))
	check("iam CreateUser", aws.ToString(created.User.UserName), "go-dev")
	_, err := im.CreateUser(ctx, &iam.CreateUserInput{UserName: aws.String("go-dev")})
	check("iam a name twice", codeOf(err), "EntityAlreadyExists")
	made := must(im.CreateAccessKey(ctx, &iam.CreateAccessKeyInput{UserName: aws.String("go-dev")})).AccessKey
	id, secret := aws.ToString(made.AccessKeyId), aws.ToString(made.SecretAccessKey)
	check("iam CreateAccessKey", []any{id[:4], len(secret) >= 40}, []any{"AKIA", true})
	listed := must(im.ListAccessKeys(ctx, &iam.ListAccessKeysInput{UserName: aws.String("go-dev")}))
	check("iam ListAccessKeys", len(listed.AccessKeyMetadata) == 1 && aws.ToString(listed.AccessKeyMetadata[0].AccessKeyId) == id, true)
	reads := `{"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::sdk-go-iam/*"}}`
	must(im.PutUserPolicy(ctx, &iam.PutUserPolicyInput{UserName: aws.String("go-dev"), PolicyName: aws.String("reads"), PolicyDocument: aws.String(reads)}))
	got := must(im.GetUserPolicy(ctx, &iam.GetUserPolicyInput{UserName: aws.String("go-dev"), PolicyName: aws.String("reads")}))
	statement, _ := policyDoc(got.PolicyDocument)["Statement"].(map[string]any)
	check("iam GetUserPolicy", statement["Action"], "s3:GetObject")
	dev := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.UsePathStyle = true
		o.Credentials = credentials.NewStaticCredentialsProvider(id, secret, "")
	})
	devReads := func() string {
		out, err := dev.GetObject(ctx, &s3.GetObjectInput{Bucket: b, Key: aws.String("a")})
		if err != nil {
			return codeOf(err)
		}
		read, _ := io.ReadAll(out.Body)
		return string(read)
	}
	check("iam its key reads within a round", within(25, func() bool { return devReads() == "read me" }), true)
	_, err = dev.PutObject(ctx, &s3.PutObjectInput{Bucket: b, Key: aws.String("no"), Body: bytes.NewReader([]byte("no"))})
	check("iam and no more", codeOf(err), "AccessDenied")
	trust := `{"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::000000000000:root"},"Action":"sts:AssumeRole"}}`
	role := must(im.CreateRole(ctx, &iam.CreateRoleInput{RoleName: aws.String("go-role"), AssumeRolePolicyDocument: aws.String(trust)}))
	check("iam CreateRole", aws.ToString(role.Role.Arn), "arn:aws:iam::000000000000:role/go-role")
	read := must(im.GetRole(ctx, &iam.GetRoleInput{RoleName: aws.String("go-role")}))
	trustStatement, _ := policyDoc(read.Role.AssumeRolePolicyDocument)["Statement"].(map[string]any)
	principal, _ := trustStatement["Principal"].(map[string]any)
	check("iam its trust read back", principal["AWS"], "arn:aws:iam::000000000000:root")
	must(im.PutRolePolicy(ctx, &iam.PutRolePolicyInput{RoleName: aws.String("go-role"), PolicyName: aws.String("reads"), PolicyDocument: aws.String(reads)}))
	st := sts.NewFromConfig(cfg)
	var assumed *sts.AssumeRoleOutput
	within(25, func() bool {
		out, err := st.AssumeRole(ctx, &sts.AssumeRoleInput{RoleArn: aws.String("arn:aws:iam::000000000000:role/go-role"), RoleSessionName: aws.String("go")})
		assumed = out
		return err == nil
	})
	check("iam the role assumed", assumed != nil && aws.ToString(assumed.Credentials.AccessKeyId)[:4] == "ASIA", true)
	if assumed != nil {
		c := assumed.Credentials
		session := s3.NewFromConfig(cfg, func(o *s3.Options) {
			o.UsePathStyle = true
			o.Credentials = credentials.NewStaticCredentialsProvider(aws.ToString(c.AccessKeyId), aws.ToString(c.SecretAccessKey), aws.ToString(c.SessionToken))
		})
		out, err := session.GetObject(ctx, &s3.GetObjectInput{Bucket: b, Key: aws.String("a")})
		body := codeOf(err)
		if err == nil {
			r, _ := io.ReadAll(out.Body)
			body = string(r)
		}
		check("iam its session reads", body, "read me")
	}
	_, err = im.DeleteUser(ctx, &iam.DeleteUserInput{UserName: aws.String("go-dev")})
	check("iam a user with keys not deleted", codeOf(err), "DeleteConflict")
	must(im.DeleteAccessKey(ctx, &iam.DeleteAccessKeyInput{UserName: aws.String("go-dev"), AccessKeyId: aws.String(id)}))
	must(im.DeleteUserPolicy(ctx, &iam.DeleteUserPolicyInput{UserName: aws.String("go-dev"), PolicyName: aws.String("reads")}))
	must(im.DeleteUser(ctx, &iam.DeleteUserInput{UserName: aws.String("go-dev")}))
	must(im.DeleteRolePolicy(ctx, &iam.DeleteRolePolicyInput{RoleName: aws.String("go-role"), PolicyName: aws.String("reads")}))
	must(im.DeleteRole(ctx, &iam.DeleteRoleInput{RoleName: aws.String("go-role")}))
	_, err = im.GetUser(ctx, &iam.GetUserInput{UserName: aws.String("go-dev")})
	check("iam the user gone", codeOf(err), "NoSuchEntity")
	check("iam its key refused within a round", within(25, func() bool { return devReads() == "InvalidAccessKeyId" }), true)
	must(account.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: b, Key: aws.String("a")}))
	must(account.DeleteBucket(ctx, &s3.DeleteBucketInput{Bucket: b}))
}
