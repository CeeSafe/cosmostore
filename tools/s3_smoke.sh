#!/bin/sh
# The M3 end-to-end test (ADR-0008 to ADR-0020): the AWS CLI v2, and tools/s3_raw.py for what the CLI does not send,
# against `cosmostore serve` on a fresh store. Prints one line per check; exit status 1 if any fails.
#
# usage: tools/s3_smoke.sh [COSMOSTORE] [PORT]     (defaults: out/cosmostore, 9311)
set -u
bin=$(cd "$(dirname "${1:-out/cosmostore}")" && pwd)/$(basename "${1:-out/cosmostore}")
port=${2:-9311}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'kill "$server" "$hook" "${limited:-}" "${remote:-}" "${maint:-}" "${usersrv:-}" 2>/dev/null; rm -rf "$work"' EXIT

export AWS_ACCESS_KEY_ID=AKIASMOKETEST0000001
export AWS_SECRET_ACCESS_KEY=smoke/secret/0123456789abcdefghijkl
export AWS_DEFAULT_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true
export AWS_ENDPOINT_URL="http://127.0.0.1:$port"
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > "$work/credentials"

# A webhook for the event notifications (ADR-0048), and a second target that nothing listens on.
hookport=$((port + 1))
: > "$work/hook.out"
start_hook() { python3 -I "$here/webhook.py" "$hookport" "$work/hook.out" & hook=$!; }
start_hook
printf 'hook http://127.0.0.1:%s/events\n# a comment\n' "$hookport" > "$work/targets"
# The master keys of SSE-S3 (ADR-0046 §4): the first seals, the second only opens.
printf '# master keys\nk2 %s\nk1 %s\n' "$(head -c 32 /dev/urandom | base64)" "$(head -c 32 /dev/urandom | base64)" > "$work/sse.keys"
# STS (ADR-0075): the keys that seal session tokens, and a role that reads the smoke bucket.
printf 'sts1 %s\n' "$(head -c 32 /dev/urandom | base64)" > "$work/sts.keys"
cat > "$work/roles" <<'ROLES'
# name, max session seconds, policy
reader 3600 {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::smoke","arn:aws:s3:::smoke/*"]}]}
ROLES
# SSE-KMS's keys (ADR-0055): the first is the default.
printf 'app-default %s\norders %s\n' "$(head -c 32 /dev/urandom | base64)" "$(head -c 32 /dev/urandom | base64)" > "$work/kms.keys"
# Replication to another endpoint (ADR-0077 §6): a second server, with keys of its own, as `far`.
remoteport=$((port + 3))
echo "AKIAFARSERVER0000001 far/secret/0123456789abcdefghij" > "$work/far.credentials"
printf 'far http://127.0.0.1:%s AKIAFARSERVER0000001 far/secret/0123456789abcdefghij\n' "$remoteport" > "$work/replication.targets"
start_server() {
    "$bin" serve "$work/store" "$port" "$work/credentials" localhost --notify-targets "$work/targets" --maintain-seconds 2 --audit-log "$work/audit.log" --sse-key-file "$work/sse.keys" --kms-key-file "$work/kms.keys" --access-log-seconds 2 --website-domain web.localhost --inventory-day-seconds 3 --sts-key-file "$work/sts.keys" --roles-file "$work/roles" --replication-targets "$work/replication.targets" --zone-id local-az1 --restore-hour-seconds 1 2>> "$work/server.log" &
    server=$!
    sleep 1
}
start_server

failed=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failed=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$3], got [$2]"; fi; }
code() { aws "$@" 2>&1 | sed -n 's/.*error occurred (\([A-Za-z0-9]*\)).*/\1/p' | head -1; }

cd "$work"
printf 'hello cosmostore\n' > small.txt
head -c 3000000 /dev/urandom > big.bin
small_etag='"5680aecbbcbe9d3d2f700cf49dbe9cd4"'

# Buckets.
aws s3api create-bucket --bucket smoke > /dev/null 2>&1 || fail "create-bucket"
check "create-bucket twice" "$(code s3api create-bucket --bucket smoke)" BucketAlreadyOwnedByYou
check "invalid bucket name" "$(code s3api create-bucket --bucket NO_)" InvalidBucketName
check "list-buckets" "$(aws s3api list-buckets --query 'Buckets[].Name' --output text)" smoke
check "bucket creation date" "$(aws s3api list-buckets --query 'Buckets[0].CreationDate' --output text | cut -c1-10)" "$(date -u +%Y-%m-%d)"
aws s3api head-bucket --bucket smoke > /dev/null 2>&1 && pass "head-bucket" || fail "head-bucket"
check "head-bucket missing" "$(code s3api head-bucket --bucket missing)" 404

# Objects: inline, extent-backed, with the CLI's default checksum and without one.
check "put small" "$(aws s3api put-object --bucket smoke --key a/small.txt --body small.txt --query ETag --output text)" "$small_etag"
aws s3api put-object --bucket smoke --key a/big.bin --body big.bin > /dev/null 2>&1 || fail "put big"
aws s3api get-object --bucket smoke --key a/big.bin got.bin > /dev/null 2>&1
cmp -s got.bin big.bin && pass "get big" || fail "get big"
AWS_REQUEST_CHECKSUM_CALCULATION=when_required aws s3api put-object --bucket smoke --key a/plain.bin --body big.bin \
    > /dev/null 2>&1 || fail "put with a signed SHA-256 payload"
aws s3 cp big.bin s3://smoke/b/cp.bin > /dev/null 2>&1 && aws s3 cp s3://smoke/b/cp.bin cp.bin > /dev/null 2>&1
cmp -s cp.bin big.bin && pass "s3 cp both ways" || fail "s3 cp both ways"
check "head-object size" "$(aws s3api head-object --bucket smoke --key a/big.bin --query ContentLength)" 3000000

# Signed aws-chunked (the Java and Go SDKs' form), and a changed chunk.
check "signed chunked put" "$(python3 -I "$here/s3_raw.py" chunked-put "$AWS_ENDPOINT_URL" smoke c/chunked.bin big.bin | head -1 | cut -d' ' -f1)" 200
aws s3api get-object --bucket smoke --key c/chunked.bin got.bin > /dev/null 2>&1
cmp -s got.bin big.bin && pass "get chunked" || fail "get chunked"
check "changed chunk refused" "$(python3 -I "$here/s3_raw.py" bad-chunk "$AWS_ENDPOINT_URL" smoke c/bad.bin big.bin | head -1 | cut -d' ' -f1)" 403
check "changed chunk not stored" "$(code s3api head-object --bucket smoke --key c/bad.bin)" 404

# Integrity.
check "wrong CRC32" "$(code s3api put-object --bucket smoke --key bad --body small.txt --checksum-crc32 AAAAAA==)" BadDigest
check "wrong Content-MD5" "$(code s3api put-object --bucket smoke --key bad --body small.txt --content-md5 AAAAAAAAAAAAAAAAAAAAAA==)" BadDigest
check "refused body not stored" "$(code s3api head-object --bucket smoke --key bad)" 404

# Ranges and conditions.
aws s3api get-object --bucket smoke --key a/small.txt --range bytes=6-9 r.txt > /dev/null 2>&1
check "range" "$(cat r.txt)" cosm
aws s3api get-object --bucket smoke --key a/small.txt --range bytes=-5 r.txt > /dev/null 2>&1
check "suffix range" "$(cat r.txt)" "tore"
check "range past the end" "$(code s3api get-object --bucket smoke --key a/small.txt --range bytes=100-200 r.txt)" InvalidRange
check "If-None-Match * on a key" "$(code s3api put-object --bucket smoke --key a/small.txt --body small.txt --if-none-match '*')" PreconditionFailed
check "If-Match right ETag" "$(aws s3api put-object --bucket smoke --key a/small.txt --body small.txt --if-match "$small_etag" --query ETag --output text)" "$small_etag"
check "If-Match wrong ETag" "$(code s3api put-object --bucket smoke --key a/small.txt --body small.txt --if-match '"00000000000000000000000000000000"')" PreconditionFailed
check "GET If-None-Match" "$(code s3api get-object --bucket smoke --key a/small.txt --if-none-match "$small_etag" x)" 304
check "GET If-Match wrong" "$(code s3api get-object --bucket smoke --key a/small.txt --if-match '"00000000000000000000000000000000"' x)" PreconditionFailed

# Keys that need encoding.
for k in "sp ace/ü+plus&amp=x.txt" "a//double" "tilde~(1)!*'"; do
    aws s3api put-object --bucket smoke --key "$k" --body small.txt > /dev/null 2>&1
    aws s3api get-object --bucket smoke --key "$k" o.txt > /dev/null 2>&1
    cmp -s o.txt small.txt && pass "key [$k]" || fail "key [$k]"
done

# Listing.
check "v2 delimiter" "$(aws s3api list-objects-v2 --bucket smoke --delimiter / --query 'CommonPrefixes[].Prefix' --output text)" "a/	b/	c/	sp ace/"
check "v2 pages of 1" "$(aws s3api list-objects-v2 --bucket smoke --prefix a/ --page-size 1 --query 'length(Contents)')" 4
check "v1 prefix" "$(aws s3api list-objects --bucket smoke --prefix b/ --query 'Contents[].Key' --output text)" b/cp.bin
check "v1 pages of 1" "$(aws s3api list-objects --bucket smoke --page-size 1 --query 'length(Contents)')" 8
check "s3 ls (url encoding)" "$(aws s3 ls s3://smoke/sp\ ace/ | awk '{print $4}')" "ü+plus&amp=x.txt"

# Multipart (ADR-0009): the CLI's own above 8 MB (8 MiB parts), then each call by hand.
head -c 20000000 /dev/urandom > huge.bin
aws s3 cp huge.bin s3://smoke/m/huge.bin > /dev/null 2>&1 && aws s3 cp s3://smoke/m/huge.bin huge.got > /dev/null 2>&1
cmp -s huge.got huge.bin && pass "s3 cp multipart both ways" || fail "s3 cp multipart both ways"
huge_etag=$(python3 -I -c '
import hashlib, sys
data = open(sys.argv[1], "rb").read()
step = 8 * 1024 * 1024
parts = [hashlib.md5(data[i:i + step]).digest() for i in range(0, len(data), step)]
print("\"%s-%d\"" % (hashlib.md5(b"".join(parts)).hexdigest(), len(parts)))' huge.bin)
check "multipart ETag" "$(aws s3api head-object --bucket smoke --key m/huge.bin --query ETag --output text)" "$huge_etag"
check "multipart ETag listed" "$(aws s3api list-objects-v2 --bucket smoke --prefix m/huge --query 'Contents[0].ETag' --output text)" "$huge_etag"
aws s3api get-object --bucket smoke --key m/huge.bin --range bytes=8388000-8389000 r.bin > /dev/null 2>&1
dd if=huge.bin of=r.want bs=1 skip=8388000 count=1001 2> /dev/null
cmp -s r.bin r.want && pass "range across parts" || fail "range across parts"
check "GET If-Match multipart ETag" "$(aws s3api get-object --bucket smoke --key m/huge.bin --if-match "$huge_etag" --range bytes=0-0 x --query ETag --output text)" "$huge_etag"
# Stored checksums and part layouts (ADR-0015).
check "checksum only when asked" "$(aws s3api head-object --bucket smoke --key a/big.bin --query 'ChecksumType' --output text)" None
check "checksum with checksum-mode" "$(aws s3api head-object --bucket smoke --key a/big.bin --checksum-mode ENABLED --query 'ChecksumType' --output text)" FULL_OBJECT
check "default CRC64NVME" "$(AWS_REQUEST_CHECKSUM_CALCULATION=when_required aws s3api put-object --bucket smoke --key a/nosum.bin --body small.txt > /dev/null 2>&1; aws s3api head-object --bucket smoke --key a/nosum.bin --checksum-mode ENABLED --query 'ChecksumCRC64NVME' --output text)" "$(python3 -I -c '
import base64, sys
data = open(sys.argv[1], "rb").read()
crc = 0xFFFFFFFFFFFFFFFF
for b in data:
    crc ^= b
    for _ in range(8):
        crc = (crc >> 1) ^ (0x9A6C9329AC4BC9B5 if crc & 1 else 0)
print(base64.b64encode((crc ^ 0xFFFFFFFFFFFFFFFF).to_bytes(8, "big")).decode())' small.txt)"
aws s3api get-object --bucket smoke --key m/huge.bin --part-number 2 part2.bin > part.json 2>&1
dd if=huge.bin of=part2.want bs=8388608 skip=1 count=1 2> /dev/null
cmp -s part2.bin part2.want && pass "get-object --part-number" || fail "get-object --part-number"
check "parts count" "$(sed -n 's/.*"PartsCount": \([0-9]*\).*/\1/p' part.json)" 3
check "get-object-attributes" "$(aws s3api get-object-attributes --bucket smoke --key m/huge.bin --object-attributes ObjectParts ObjectSize --query '[ObjectSize,ObjectParts.TotalPartsCount]' --output text)" "20000000	3"
check "part number past the last" "$(code s3api get-object --bucket smoke --key m/huge.bin --part-number 4 x)" InvalidPart

head -c 5242880 /dev/urandom > p1.bin
id=$(aws s3api create-multipart-upload --bucket smoke --key m/manual --content-type text/x-test --query UploadId --output text)
e1=$(aws s3api upload-part --bucket smoke --key m/manual --upload-id "$id" --part-number 1 --body p1.bin --query ETag --output text | tr -d '"')
e2=$(aws s3api upload-part --bucket smoke --key m/manual --upload-id "$id" --part-number 2 --body small.txt --query ETag --output text | tr -d '"')
e3=$(aws s3api upload-part --bucket smoke --key m/manual --upload-id "$id" --part-number 3 --body small.txt --query ETag --output text | tr -d '"')
check "upload-part ETag" "$e2" "$(echo "$small_etag" | tr -d '"')"
check "list-parts" "$(aws s3api list-parts --bucket smoke --key m/manual --upload-id "$id" --query 'Parts[].PartNumber' --output text)" "1	2	3"
check "list-parts page" "$(aws s3api list-parts --bucket smoke --key m/manual --upload-id "$id" --max-parts 1 --part-number-marker 1 --query 'Parts[].Size' --output text)" 17
check "list-multipart-uploads" "$(aws s3api list-multipart-uploads --bucket smoke --query 'Uploads[].Key' --output text)" m/manual
check "complete: wrong ETag" "$(code s3api complete-multipart-upload --bucket smoke --key m/manual --upload-id "$id" --multipart-upload "{\"Parts\":[{\"ETag\":\"$e2\",\"PartNumber\":1}]}")" InvalidPart
check "complete: small part first" "$(code s3api complete-multipart-upload --bucket smoke --key m/manual --upload-id "$id" --multipart-upload "{\"Parts\":[{\"ETag\":\"$e2\",\"PartNumber\":2},{\"ETag\":\"$e3\",\"PartNumber\":3}]}")" EntityTooSmall
check "complete: out of order" "$(code s3api complete-multipart-upload --bucket smoke --key m/manual --upload-id "$id" --multipart-upload "{\"Parts\":[{\"ETag\":\"$e2\",\"PartNumber\":2},{\"ETag\":\"$e1\",\"PartNumber\":1}]}")" InvalidPartOrder
manual_etag=$(aws s3api complete-multipart-upload --bucket smoke --key m/manual --upload-id "$id" \
    --multipart-upload "{\"Parts\":[{\"ETag\":\"$e1\",\"PartNumber\":1},{\"ETag\":\"$e2\",\"PartNumber\":2}]}" --query ETag --output text)
check "complete ETag" "$manual_etag" "$(python3 -I -c '
import hashlib, sys
print("\"%s-2\"" % hashlib.md5(bytes.fromhex(sys.argv[1]) + bytes.fromhex(sys.argv[2])).hexdigest())' "$e1" "$e2")"
aws s3api get-object --bucket smoke --key m/manual got.bin > /dev/null 2>&1
cat p1.bin small.txt > want.bin
cmp -s got.bin want.bin && pass "completed object" || fail "completed object"
check "completed content type" "$(aws s3api head-object --bucket smoke --key m/manual --query ContentType --output text)" text/x-test
check "completed upload gone" "$(code s3api list-parts --bucket smoke --key m/manual --upload-id "$id")" NoSuchUpload
id=$(aws s3api create-multipart-upload --bucket smoke --key m/aborted --query UploadId --output text)
aws s3api upload-part --bucket smoke --key m/aborted --upload-id "$id" --part-number 1 --body p1.bin > /dev/null 2>&1
aws s3api abort-multipart-upload --bucket smoke --key m/aborted --upload-id "$id" > /dev/null 2>&1 && pass "abort" || fail "abort"
check "aborted upload gone" "$(code s3api upload-part --bucket smoke --key m/aborted --upload-id "$id" --part-number 2 --body small.txt)" NoSuchUpload
check "no uploads left" "$(aws s3api list-multipart-uploads --bucket smoke --query 'length(Uploads || `[]`)')" 0
check "unknown upload id" "$(code s3api abort-multipart-upload --bucket smoke --key m/x --upload-id nope)" NoSuchUpload

# Copies (ADR-0010): whole objects, the CLI's multipart copy (UploadPartCopy above 8 MB), and part ranges by hand.
aws s3api copy-object --bucket smoke --key c/copy1 --copy-source smoke/m/manual > /dev/null 2>&1
aws s3api get-object --bucket smoke --key c/copy1 got.bin > /dev/null 2>&1
cmp -s got.bin want.bin && pass "copy-object" || fail "copy-object"
check "copy keeps the content type" "$(aws s3api head-object --bucket smoke --key c/copy1 --query ContentType --output text)" text/x-test
check "copy of a multipart object is one part" "$(aws s3api head-object --bucket smoke --key c/copy1 --query ETag --output text)" "\"$(md5 -q want.bin)\""
aws s3api copy-object --bucket smoke --key c/copy1 --copy-source smoke/c/copy1 --metadata-directive REPLACE --content-type x/y > /dev/null 2>&1
check "copy onto itself, REPLACE" "$(aws s3api head-object --bucket smoke --key c/copy1 --query ContentType --output text)" x/y
check "copy onto itself, COPY" "$(code s3api copy-object --bucket smoke --key c/copy1 --copy-source smoke/c/copy1)" InvalidRequest
check "copy of a missing key" "$(code s3api copy-object --bucket smoke --key c/x --copy-source smoke/nope)" NoSuchKey
check "copy-source-if-match wrong" "$(code s3api copy-object --bucket smoke --key c/x --copy-source smoke/c/copy1 --copy-source-if-match '"00000000000000000000000000000000"')" PreconditionFailed
check "copy If-None-Match * onto an object" "$(code s3api copy-object --bucket smoke --key c/copy1 --copy-source smoke/a/small.txt --if-none-match '*')" PreconditionFailed
check "copy If-Match wrong" "$(code s3api copy-object --bucket smoke --key c/copy1 --copy-source smoke/a/small.txt --if-match '"00000000000000000000000000000000"')" PreconditionFailed
check "copy If-Match missing key" "$(code s3api copy-object --bucket smoke --key c/none --copy-source smoke/a/small.txt --if-match "$small_etag")" NoSuchKey
check "copy If-None-Match * onto nothing" "$(aws s3api copy-object --bucket smoke --key c/fresh --copy-source smoke/a/small.txt --if-none-match '*' --query CopyObjectResult.ETag --output text)" "$small_etag"
aws s3api put-object --bucket smoke --key "c/sp ace+ü.txt" --body small.txt > /dev/null 2>&1
aws s3 cp "s3://smoke/c/sp ace+ü.txt" s3://smoke/c/enc.txt > /dev/null 2>&1
aws s3api get-object --bucket smoke --key c/enc.txt o.txt > /dev/null 2>&1
cmp -s o.txt small.txt && pass "copy of an encoded key" || fail "copy of an encoded key"
rm -f huge.got; aws s3 cp s3://smoke/m/huge.bin s3://smoke/c/huge.bin > /dev/null 2>&1 && aws s3 cp s3://smoke/c/huge.bin huge.got > /dev/null 2>&1
cmp -s huge.got huge.bin && pass "s3 cp S3 to S3 (UploadPartCopy)" || fail "s3 cp S3 to S3 (UploadPartCopy)"
check "UploadPartCopy ETag" "$(aws s3api head-object --bucket smoke --key c/huge.bin --query ETag --output text)" "$huge_etag"
id=$(aws s3api create-multipart-upload --bucket smoke --key c/ranged --query UploadId --output text)
r1=$(aws s3api upload-part-copy --bucket smoke --key c/ranged --upload-id "$id" --part-number 1 --copy-source smoke/m/huge.bin --copy-source-range bytes=1000-5243879 --query CopyPartResult.ETag --output text | tr -d '"')
r2=$(aws s3api upload-part-copy --bucket smoke --key c/ranged --upload-id "$id" --part-number 2 --copy-source smoke/a/small.txt --query CopyPartResult.ETag --output text | tr -d '"')
check "part copy range past the end" "$(code s3api upload-part-copy --bucket smoke --key c/ranged --upload-id "$id" --part-number 3 --copy-source smoke/a/small.txt --copy-source-range bytes=0-17)" InvalidRange
aws s3api complete-multipart-upload --bucket smoke --key c/ranged --upload-id "$id" \
    --multipart-upload "{\"Parts\":[{\"ETag\":\"$r1\",\"PartNumber\":1},{\"ETag\":\"$r2\",\"PartNumber\":2}]}" > /dev/null 2>&1
aws s3api get-object --bucket smoke --key c/ranged got.bin > /dev/null 2>&1
{ dd if=huge.bin bs=1000 skip=1 count=5242 2> /dev/null; dd if=huge.bin bs=1 skip=5243000 count=880 2> /dev/null; cat small.txt; } > want2.bin
cmp -s got.bin want2.bin && pass "upload-part-copy ranges" || fail "upload-part-copy ranges"

# DeleteObjects (ADR-0010): one commit for the batch; missing keys count as deleted.
check "delete-objects" "$(aws s3api delete-objects --bucket smoke --delete '{"Objects":[{"Key":"c/copy1"},{"Key":"c/none"},{"Key":"c/enc.txt"}]}' --query 'length(Deleted)')" 3
check "deleted by the batch" "$(code s3api head-object --bucket smoke --key c/copy1)" 404
check "delete-objects quiet" "$(aws s3api delete-objects --bucket smoke --delete '{"Objects":[{"Key":"c/ranged"}],"Quiet":true}' --query 'length(Deleted || `[]`)')" 0

# Stored fields (ADR-0012): user metadata and the headers S3 keeps, through PUT, multipart and copies.
aws s3api put-object --bucket smoke --key meta/one --body small.txt --metadata mtime=1731000000,Color=Blue \
    --content-encoding gzip --cache-control max-age=60 --content-disposition 'attachment; filename="x.txt"' > /dev/null 2>&1
check "user metadata" "$(aws s3api head-object --bucket smoke --key meta/one --query 'Metadata' --output json | tr -d ' \n')" '{"mtime":"1731000000","color":"Blue"}'
check "stored headers" "$(aws s3api head-object --bucket smoke --key meta/one --query '[ContentEncoding,CacheControl,ContentDisposition]' --output text)" 'gzip	max-age=60	attachment; filename="x.txt"'
check "aws-chunked is not stored" "$(aws s3api head-object --bucket smoke --key a/small.txt --query 'ContentEncoding' --output text)" None
signed() { curl -s --aws-sigv4 "aws:amz:us-east-1:s3" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" "$@"; }
check "response-* overrides a stored header" "$(signed -D - -o /dev/null "$AWS_ENDPOINT_URL/smoke/meta/one?response-cache-control=no-store" | tr -d '\r' | grep -i '^cache-control:')" "cache-control: no-store"
aws s3 cp huge.bin s3://smoke/meta/huge --metadata origin=smoke > /dev/null 2>&1
check "multipart metadata" "$(aws s3api head-object --bucket smoke --key meta/huge --query 'Metadata.origin' --output text)" smoke
aws s3api copy-object --bucket smoke --key meta/copy --copy-source smoke/meta/one > /dev/null 2>&1
check "copy keeps metadata" "$(aws s3api head-object --bucket smoke --key meta/copy --query 'Metadata.color' --output text)" Blue
aws s3api copy-object --bucket smoke --key meta/copy --copy-source smoke/meta/one --metadata-directive REPLACE --metadata new=1 > /dev/null 2>&1
check "copy REPLACE replaces metadata" "$(aws s3api head-object --bucket smoke --key meta/copy --query 'Metadata' --output json | tr -d ' \n')" '{"new":"1"}'
check "metadata too large" "$(code s3api put-object --bucket smoke --key meta/big --body small.txt --metadata "big=$(head -c 2100 /dev/zero | tr '\0' a)")" MetadataTooLarge
aws s3 rm --recursive s3://smoke/meta/ > /dev/null 2>&1

# Presigned URLs (ADR-0011): the CLI's GET, a PUT through curl, a changed URL, and an expired one.
url=$(aws s3 presign s3://smoke/a/small.txt --expires-in 60)
check "presigned GET" "$(curl -s "$url")" "hello cosmostore"
check "presigned GET, changed key" "$(curl -s -o /dev/null -w '%{http_code}' "$(echo "$url" | sed 's|a/small.txt|a/big.bin|')")" 403
url=$(python3 -I "$here/s3_raw.py" presign "$AWS_ENDPOINT_URL" PUT smoke p/presigned.txt 60)
check "presigned PUT" "$(curl -s -o /dev/null -w '%{http_code}' -X PUT --data-binary @small.txt "$url")" 200
aws s3api get-object --bucket smoke --key p/presigned.txt o.txt > /dev/null 2>&1
cmp -s o.txt small.txt && pass "presigned PUT stored" || fail "presigned PUT stored"
url=$(python3 -I "$here/s3_raw.py" presign "$AWS_ENDPOINT_URL" GET smoke a/small.txt 1)
sleep 2
check "presigned URL expired" "$(curl -s "$url" | sed -n 's/.*<Code>\(.*\)<\/Code>.*/\1/p')" AccessDenied
check "presigned without a signature" "$(curl -s "$(echo "$url" | sed 's/&X-Amz-Signature=.*//')" | sed -n 's/.*<Code>\(.*\)<\/Code>.*/\1/p')" AuthorizationQueryParametersError

# Virtual-host addressing (ADR-0011): `smoke.localhost` names the bucket.
printf '[default]\ns3 =\n  addressing_style = virtual\n' > virtual.cfg
vhost() { AWS_CONFIG_FILE="$work/virtual.cfg" AWS_ENDPOINT_URL="http://localhost:$port" aws "$@"; }
vhost s3api put-object --bucket smoke --key v/hosted.txt --body small.txt > /dev/null 2>&1
check "virtual-host GET" "$(curl -s "$(vhost s3 presign s3://smoke/v/hosted.txt)")" "hello cosmostore"
vhost s3 cp big.bin s3://smoke/v/big.bin > /dev/null 2>&1 && vhost s3 cp s3://smoke/v/big.bin vg.bin > /dev/null 2>&1
cmp -s vg.bin big.bin && pass "virtual-host cp both ways" || fail "virtual-host cp both ways"
check "virtual-host list" "$(vhost s3api list-objects-v2 --bucket smoke --prefix v/ --query 'Contents[].Key' --output text)" "v/big.bin	v/hosted.txt"
aws s3 rm --recursive s3://smoke/v/ > /dev/null 2>&1
aws s3 rm --recursive s3://smoke/p/ > /dev/null 2>&1

# A GET dropped half way releases its pins: the overwritten extents go on the next commits.
for i in 1 2 3; do python3 -I "$here/s3_raw.py" abort-get "$AWS_ENDPOINT_URL" smoke a/big.bin 100000 > /dev/null; done
aws s3api put-object --bucket smoke --key a/big.bin --body small.txt > /dev/null 2>&1
aws s3api delete-object --bucket smoke --key a/nothing > /dev/null 2>&1

# Errors and auth.
check "no such key" "$(code s3api get-object --bucket smoke --key nope x)" NoSuchKey
check "no such bucket" "$(code s3api get-object --bucket missing --key nope x)" NoSuchBucket
# A small PUT is refused at staging, after its body (ADR-0032); a large one before.
check "small PUT, no such bucket" "$(code s3api put-object --bucket missing --key k --body small.txt)" NoSuchBucket
check "large PUT, no such bucket" "$(code s3api put-object --bucket missing --key k --body big.bin)" NoSuchBucket
check "bucket not empty" "$(code s3api delete-bucket --bucket smoke)" BucketNotEmpty
check "wrong secret" "$(AWS_SECRET_ACCESS_KEY=wrong code s3api list-buckets)" SignatureDoesNotMatch
check "unknown key id" "$(AWS_ACCESS_KEY_ID=AKIAUNKNOWN code s3api list-buckets)" InvalidAccessKeyId
check "anonymous" "$(code s3api list-buckets --no-sign-request)" AccessDenied
# Tags (ADR-0017).
check "no tags" "$(aws s3api get-object-tagging --bucket smoke --key a/small.txt --query 'length(TagSet)')" 0
aws s3api put-object --bucket smoke --key t/one --body small.txt --tagging 'team=blue&tier=gold%20plus' > /dev/null 2>&1
check "tags at put" "$(aws s3api get-object-tagging --bucket smoke --key t/one --query 'TagSet[].[Key,Value]' --output text | tr '\t\n' '=;')" "team=blue;tier=gold plus;"
check "tag count on HEAD" "$(aws s3api head-object --bucket smoke --key t/one --query TagCount)" 2
etag_before=$(aws s3api head-object --bucket smoke --key t/one --query ETag --output text)
aws s3api put-object-tagging --bucket smoke --key t/one --tagging 'TagSet=[{Key=state,Value=done}]' > /dev/null 2>&1
check "put-object-tagging" "$(aws s3api get-object-tagging --bucket smoke --key t/one --query 'TagSet[0].Value' --output text)" done
check "tags keep the version" "$(aws s3api head-object --bucket smoke --key t/one --query ETag --output text)" "$etag_before"
aws s3api copy-object --bucket smoke --key t/copy --copy-source smoke/t/one > /dev/null 2>&1
check "copy keeps tags" "$(aws s3api get-object-tagging --bucket smoke --key t/copy --query 'TagSet[0].Key' --output text)" state
aws s3api copy-object --bucket smoke --key t/copy --copy-source smoke/t/one --tagging-directive REPLACE --tagging 'new=1' > /dev/null 2>&1
check "copy REPLACE tags" "$(aws s3api get-object-tagging --bucket smoke --key t/copy --query 'TagSet[0].Key' --output text)" new
aws s3api delete-object-tagging --bucket smoke --key t/one > /dev/null 2>&1
check "delete-object-tagging" "$(aws s3api get-object-tagging --bucket smoke --key t/one --query 'length(TagSet)')" 0
check "eleven tags" "$(code s3api put-object-tagging --bucket smoke --key t/one --tagging 'TagSet=[{Key=a,Value=1},{Key=b,Value=1},{Key=c,Value=1},{Key=d,Value=1},{Key=e,Value=1},{Key=f,Value=1},{Key=g,Value=1},{Key=h,Value=1},{Key=i,Value=1},{Key=j,Value=1},{Key=k,Value=1}]')" InvalidTag
check "tags on a missing key" "$(code s3api put-object-tagging --bucket smoke --key t/none --tagging 'TagSet=[{Key=a,Value=1}]')" NoSuchKey
aws s3 rm --recursive s3://smoke/t/ > /dev/null 2>&1

# Bucket tags and lifecycle rules (ADR-0020).
check "no bucket tags" "$(code s3api get-bucket-tagging --bucket smoke)" NoSuchTagSet
aws s3api put-bucket-tagging --bucket smoke --tagging 'TagSet=[{Key=env,Value=test},{Key=owner,Value=smoke}]' > /dev/null 2>&1
check "bucket tags" "$(aws s3api get-bucket-tagging --bucket smoke --query 'TagSet[].Key' --output text)" "env	owner"
aws s3api delete-bucket-tagging --bucket smoke > /dev/null 2>&1
check "bucket tags deleted" "$(code s3api get-bucket-tagging --bucket smoke)" NoSuchTagSet
check "no lifecycle" "$(code s3api get-bucket-lifecycle-configuration --bucket smoke)" NoSuchLifecycleConfiguration
aws s3api put-bucket-lifecycle-configuration --bucket smoke --lifecycle-configuration '{"Rules":[
  {"ID":"logs","Filter":{"Prefix":"logs/"},"Status":"Enabled","Expiration":{"Days":30}},
  {"ID":"uploads","Filter":{"Prefix":""},"Status":"Enabled","AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}' > /dev/null 2>&1
check "lifecycle rules" "$(aws s3api get-bucket-lifecycle-configuration --bucket smoke --query 'Rules[].[ID,Expiration.Days,AbortIncompleteMultipartUpload.DaysAfterInitiation]' --output text | tr '\t\n' ' ;')" "logs 30 None;uploads None 7;"
check "a transition to a class not kept here refused (ADR-0090 §2)" "$(code s3api put-bucket-lifecycle-configuration --bucket smoke --lifecycle-configuration '{"Rules":[{"ID":"t","Filter":{"Prefix":""},"Status":"Enabled","Transitions":[{"Days":1,"StorageClass":"SHELF"}]}]}')" InvalidStorageClass
aws s3api put-bucket-lifecycle-configuration --bucket smoke --lifecycle-configuration '{"Rules":[
  {"ID":"old","Filter":{"Prefix":"docs/"},"Status":"Enabled","NoncurrentVersionExpiration":{"NoncurrentDays":30,"NewerNoncurrentVersions":3}},
  {"ID":"markers","Filter":{"Prefix":""},"Status":"Enabled","Expiration":{"ExpiredObjectDeleteMarker":true}}]}' > /dev/null 2>&1
check "lifecycle rules for versions" "$(aws s3api get-bucket-lifecycle-configuration --bucket smoke --query 'Rules[].[ID,NoncurrentVersionExpiration.NoncurrentDays,NoncurrentVersionExpiration.NewerNoncurrentVersions,Expiration.ExpiredObjectDeleteMarker]' --output text | tr '\t\n' ' ;')" "old 30 3 None;markers None None True;"
check "too many versions to keep" "$(code s3api put-bucket-lifecycle-configuration --bucket smoke --lifecycle-configuration '{"Rules":[{"ID":"n","Filter":{"Prefix":""},"Status":"Enabled","NoncurrentVersionExpiration":{"NoncurrentDays":1,"NewerNoncurrentVersions":101}}]}')" InvalidArgument
aws s3api delete-bucket-lifecycle --bucket smoke > /dev/null 2>&1
check "lifecycle deleted" "$(code s3api get-bucket-lifecycle-configuration --bucket smoke)" NoSuchLifecycleConfiguration

# Versions (ADR-0041): the bucket's versioning, version ids on writes and reads, delete markers, the listing.
aws s3api create-bucket --bucket ver > /dev/null 2>&1
check "versioning never set" "$(aws s3api get-bucket-versioning --bucket ver --query Status --output text)" None
check "a bad versioning status" "$(code s3api put-bucket-versioning --bucket ver --versioning-configuration Status=Off)" MalformedXML
aws s3api put-bucket-versioning --bucket ver --versioning-configuration Status=Enabled > /dev/null 2>&1 || fail "put-bucket-versioning"
check "versioning enabled" "$(aws s3api get-bucket-versioning --bucket ver --query Status --output text)" Enabled
printf one > v1.txt
printf two > v2.txt
v1=$(aws s3api put-object --bucket ver --key k --body v1.txt --query VersionId --output text)
v2=$(aws s3api put-object --bucket ver --key k --body v2.txt --query VersionId --output text)
check "each put has its version id" "$([ ${#v1} = 32 ] && [ ${#v2} = 32 ] && [ "$v1" != "$v2" ] && echo yes)" yes
aws s3api get-object --bucket ver --key k --version-id "$v1" got.txt > /dev/null 2>&1
check "get by version id" "$(cat got.txt)" one
check "get names the current version" "$(aws s3api get-object --bucket ver --key k got.txt --query VersionId --output text)" "$v2"
check "head by version id" "$(aws s3api head-object --bucket ver --key k --version-id "$v1" --query '[ContentLength,VersionId]' --output text)" "3	$v1"
check "no such version" "$(code s3api get-object --bucket ver --key k --version-id 00112233445566778899aabbccddeeff got.txt)" NoSuchVersion
check "not a version id" "$(code s3api get-object --bucket ver --key k --version-id nope got.txt)" InvalidArgument
aws s3api put-object-tagging --bucket ver --key k --version-id "$v1" --tagging 'TagSet=[{Key=which,Value=first}]' > /dev/null 2>&1
check "tags by version id" "$(aws s3api get-object-tagging --bucket ver --key k --version-id "$v1" --query 'TagSet[0].Value' --output text)" first
check "the current version has no tags" "$(aws s3api get-object-tagging --bucket ver --key k --query 'length(TagSet)')" 0
check "copy from a version" "$(aws s3api copy-object --bucket ver --key copy --copy-source "ver/k?versionId=$v1" --query CopySourceVersionId --output text)" "$v1"
aws s3api get-object --bucket ver --key copy got.txt > /dev/null 2>&1
check "the copy is that version" "$(cat got.txt)" one
deleted=$(aws s3api delete-object --bucket ver --key k --query '[DeleteMarker,VersionId]' --output text)
marker=$(printf '%s' "$deleted" | cut -f2)
check "delete writes a marker" "$(printf '%s' "$deleted" | cut -f1)" True
check "get under a marker" "$(code s3api get-object --bucket ver --key k got.txt)" NoSuchKey
check "the 404 names the marker" "$(curl -s -o /dev/null -D - "$(aws s3 presign s3://ver/k)" | tr -d '\r' | grep -i '^x-amz-delete-marker\|^x-amz-version-id' | sort | cut -d' ' -f2 | tr '\n' ' ')" "true $marker "
check "get a marker by its id" "$(code s3api get-object --bucket ver --key k --version-id "$marker" got.txt)" MethodNotAllowed
check "a marker is not listed" "$(aws s3api list-objects-v2 --bucket ver --query 'Contents[].Key' --output text)" copy
aws s3api get-object --bucket ver --key k --version-id "$v2" got.txt > /dev/null 2>&1
check "versions stay under a marker" "$(cat got.txt)" two
check "list-object-versions" "$(aws s3api list-object-versions --bucket ver --prefix k --query '[Versions[].VersionId,Versions[].IsLatest,DeleteMarkers[].VersionId,DeleteMarkers[].IsLatest]' --output text | tr '\t\n' ' ;')" "$v2 $v1;False False;$marker;True;"
check "versions in pages of one" "$(aws s3api list-object-versions --bucket ver --page-size 1 --output json --query '[length(Versions),length(DeleteMarkers)]' | tr -d ' \n')" "[3,1]"
check "one page of one" "$(aws s3api list-object-versions --bucket ver --max-keys 1 --no-paginate --query '[IsTruncated,NextKeyMarker,length(Versions)]' --output text)" "True	copy	1"
check "delete-bucket with versions" "$(code s3api delete-bucket --bucket ver)" BucketNotEmpty
check "delete the marker" "$(aws s3api delete-object --bucket ver --key k --version-id "$marker" --query '[DeleteMarker,VersionId]' --output text)" "True	$marker"
check "the object is back" "$(aws s3api get-object --bucket ver --key k got.txt --query VersionId --output text)" "$v2"
printf '{"Objects":[{"Key":"k","VersionId":"%s"},{"Key":"k"},{"Key":"k","VersionId":"nope"}]}' "$v1" > delete.json
check "delete-objects with versions" "$(aws s3api delete-objects --bucket ver --delete file://delete.json --query '[Deleted[0].VersionId,Deleted[1].DeleteMarker,Errors[0].Code]' --output text)" "$v1	True	NoSuchVersion"
aws s3api put-bucket-versioning --bucket ver --versioning-configuration Status=Suspended > /dev/null 2>&1
check "versioning suspended" "$(aws s3api get-bucket-versioning --bucket ver --query Status --output text)" Suspended
check "a suspended put has the null version" "$(aws s3api put-object --bucket ver --key k --body v1.txt --query VersionId --output text)" None
check "the null version is the latest" "$(aws s3api list-object-versions --bucket ver --prefix k --query 'Versions[?IsLatest].VersionId' --output text)" null
check "get the null version" "$(aws s3api get-object --bucket ver --key k --version-id null got.txt --query VersionId --output text)" null
for kind in Versions DeleteMarkers; do
    aws s3api list-object-versions --bucket ver --query "$kind[].[Key,VersionId]" --output text | while read -r k v; do
        [ "$k" = None ] && continue
        aws s3api delete-object --bucket ver --key "$k" --version-id "$v" > /dev/null 2>&1
    done
done
check "every version deleted" "$(aws s3api list-object-versions --bucket ver --query '[Versions,DeleteMarkers]' --output text | tr '\t\n' '  ')" "None None "
aws s3api delete-bucket --bucket ver > /dev/null 2>&1 && pass "delete-bucket without versions" || fail "delete-bucket without versions"
check "an unversioned bucket's versions" "$(aws s3api list-object-versions --bucket smoke --max-keys 2 --no-paginate --query 'Versions[].[VersionId,IsLatest]' --output text | tr '\t\n' ' ;')" "null True;null True;"

# Bucket policies (ADR-0043): anonymous reads by an Allow, a key refused by a Deny, conditions, and no lockout.
anon() { curl -s -o anon.out -w '%{http_code}' "$@"; }
aws s3api create-bucket --bucket pol > /dev/null 2>&1
printf 'public bytes' > pub.txt
aws s3api put-object --bucket pol --key pub/a.txt --body pub.txt > /dev/null 2>&1
aws s3api put-object --bucket pol --key priv/b.txt --body pub.txt > /dev/null 2>&1
aws s3api put-object --bucket pol --key keep/k.txt --body pub.txt > /dev/null 2>&1
check "no policy" "$(code s3api get-bucket-policy --bucket pol)" NoSuchBucketPolicy
check "anonymous without a policy" "$(anon "$AWS_ENDPOINT_URL/pol/pub/a.txt")" 403
cat > policy.json <<JSON
{"Version": "2012-10-17", "Statement": [
  {"Sid": "read", "Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::pol/pub/*"},
  {"Sid": "drop", "Effect": "Allow", "Principal": {"AWS": "*"}, "Action": "s3:PutObject", "Resource": "arn:aws:s3:::pol/drop/*"},
  {"Sid": "keep", "Effect": "Deny", "Principal": {"AWS": "arn:aws:iam:::user/$AWS_ACCESS_KEY_ID"},
   "Action": ["s3:DeleteObject", "s3:DeleteObjectVersion"], "Resource": "arn:aws:s3:::pol/keep/*"}]}
JSON
aws s3api put-bucket-policy --bucket pol --policy file://policy.json > /dev/null 2>&1 || fail "put-bucket-policy"
check "get-bucket-policy" "$(aws s3api get-bucket-policy --bucket pol --query Policy --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["Statement"][0]["Sid"])')" read
check "anonymous read by the policy" "$(anon "$AWS_ENDPOINT_URL/pol/pub/a.txt") $(cat anon.out)" "200 public bytes"
check "anonymous head" "$(anon -I "$AWS_ENDPOINT_URL/pol/pub/a.txt")" 200
check "anonymous read outside it" "$(anon "$AWS_ENDPOINT_URL/pol/priv/b.txt")" 403
check "anonymous list" "$(anon "$AWS_ENDPOINT_URL/pol?list-type=2")" 403
check "anonymous put outside it" "$(anon -X PUT --data-binary @pub.txt "$AWS_ENDPOINT_URL/pol/pub/x.txt")" 403
check "anonymous put by the policy" "$(anon -X PUT --data-binary @pub.txt "$AWS_ENDPOINT_URL/pol/drop/x.txt")" 200
check "the anonymous object" "$(aws s3api head-object --bucket pol --key drop/x.txt --query ContentLength)" 12
check "anonymous service" "$(anon "$AWS_ENDPOINT_URL/")" 403
check "anonymous create-bucket" "$(anon -X PUT "$AWS_ENDPOINT_URL/anon-made")" 403
check "a key denied by the policy" "$(code s3api delete-object --bucket pol --key keep/k.txt)" AccessDenied
check "a key allowed elsewhere" "$(aws s3api get-object --bucket pol --key keep/k.txt got.txt > /dev/null 2>&1 && cat got.txt)" "public bytes"
check "delete-objects, one key denied" "$(aws s3api delete-objects --bucket pol --delete '{"Objects":[{"Key":"keep/k.txt"},{"Key":"drop/x.txt"}]}' --query '[Errors[0].Key,Errors[0].Code,Deleted[0].Key]' --output text)" "keep/k.txt	AccessDenied	drop/x.txt"
cat > policy.json <<JSON
{"Statement": [{"Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::pol/pub/*",
  "Condition": {"IpAddress": {"aws:SourceIp": "10.0.0.0/8"}}}]}
JSON
aws s3api put-bucket-policy --bucket pol --policy file://policy.json > /dev/null 2>&1
check "anonymous from outside the range" "$(anon "$AWS_ENDPOINT_URL/pol/pub/a.txt")" 403
sed 's|10.0.0.0/8|127.0.0.0/8|' policy.json > policy2.json
aws s3api put-bucket-policy --bucket pol --policy file://policy2.json > /dev/null 2>&1
check "anonymous from inside it" "$(anon "$AWS_ENDPOINT_URL/pol/pub/a.txt")" 200
printf '%s' '{"Statement": [{"Effect": "Deny", "Principal": "*", "Action": "s3:*", "Resource": ["arn:aws:s3:::pol", "arn:aws:s3:::pol/*"]}]}' > deny.json
aws s3api put-bucket-policy --bucket pol --policy file://deny.json > /dev/null 2>&1
check "a key under a Deny of everything" "$(code s3api list-objects-v2 --bucket pol)" AccessDenied
check "the policy calls stay open" "$(aws s3api get-bucket-policy --bucket pol --query Policy --output text | cut -c1-14)" '{"Statement": '
check "a malformed policy" "$(code s3api put-bucket-policy --bucket pol --policy '{"Statement": []}')" MalformedPolicy
check "another bucket's resource" "$(code s3api put-bucket-policy --bucket pol --policy '{"Statement": {"Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::smoke/*"}}')" MalformedPolicy
check "a key that is not configured" "$(code s3api put-bucket-policy --bucket pol --policy '{"Statement": {"Effect": "Allow", "Principal": {"AWS": "arn:aws:iam:::user/AKIANOBODY"}, "Action": "s3:GetObject", "Resource": "arn:aws:s3:::pol/*"}}')" MalformedPolicy
check "a condition not evaluated" "$(code s3api put-bucket-policy --bucket pol --policy '{"Statement": {"Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::pol/*", "Condition": {"DateGreaterThan": {"aws:CurrentTime": "2030-01-01T00:00:00Z"}}}}')" NotImplemented
aws s3api delete-bucket-policy --bucket pol > /dev/null 2>&1 || fail "delete-bucket-policy"
check "no policy again" "$(code s3api get-bucket-policy --bucket pol)" NoSuchBucketPolicy
check "anonymous after it" "$(anon "$AWS_ENDPOINT_URL/pol/pub/a.txt")" 403
check "the key after it" "$(aws s3api delete-object --bucket pol --key keep/k.txt > /dev/null 2>&1 && echo deleted)" deleted

# The policy's status and the public-access block (ADR-0044).
status() { aws s3api get-bucket-policy-status --bucket pol --query PolicyStatus.IsPublic; }
block() { aws s3api put-public-access-block --bucket pol --public-access-block-configuration "$1" > /dev/null 2>&1; }
check "no public-access block" "$(code s3api get-public-access-block --bucket pol)" NoSuchPublicAccessBlockConfiguration
check "the status without a policy" "$(status)" false
aws s3api put-bucket-policy --bucket pol --policy file://policy2.json > /dev/null 2>&1
check "the status of a policy for fixed addresses" "$(status)" false
printf '%s' '{"Statement": [{"Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::pol/pub/*"}]}' > public.json
aws s3api put-bucket-policy --bucket pol --policy file://public.json > /dev/null 2>&1
check "the status of a public policy" "$(status)" true
check "anonymous status" "$(anon "$AWS_ENDPOINT_URL/pol?policyStatus")" 403
block BlockPublicAcls=true,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=true || fail "put-public-access-block"
check "get-public-access-block" "$(aws s3api get-public-access-block --bucket pol --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text | tr '\t' ' ')" "True False False True"
check "anonymous under RestrictPublicBuckets" "$(anon "$AWS_ENDPOINT_URL/pol/pub/a.txt")" 403
check "a key under it" "$(aws s3api get-object --bucket pol --key pub/a.txt got.txt > /dev/null 2>&1 && cat got.txt)" "public bytes"
check "the policy stays" "$(status)" true
aws s3api put-bucket-policy --bucket pol --policy file://policy2.json > /dev/null 2>&1
check "anonymous by a policy that is not public" "$(anon "$AWS_ENDPOINT_URL/pol/pub/a.txt")" 200
block BlockPublicPolicy=true || fail "put-public-access-block again"
check "the block replaced" "$(aws s3api get-public-access-block --bucket pol --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text | tr '\t' ' ')" "False False True False"
check "a public policy under BlockPublicPolicy" "$(code s3api put-bucket-policy --bucket pol --policy file://public.json)" AccessDenied
aws s3api put-bucket-policy --bucket pol --policy file://policy2.json > /dev/null 2>&1 && pass "one that is not public" || fail "one that is not public"
aws s3api delete-public-access-block --bucket pol > /dev/null 2>&1 || fail "delete-public-access-block"
check "no public-access block again" "$(code s3api get-public-access-block --bucket pol)" NoSuchPublicAccessBlockConfiguration
aws s3api put-bucket-policy --bucket pol --policy file://public.json > /dev/null 2>&1 && pass "a public policy after it" || fail "a public policy after it"
check "anonymous after it" "$(anon "$AWS_ENDPOINT_URL/pol/pub/a.txt")" 200
aws s3api delete-bucket-policy --bucket pol > /dev/null 2>&1
aws s3 rm --recursive s3://pol/ > /dev/null 2>&1
aws s3api put-bucket-policy --bucket pol --policy file://deny.json > /dev/null 2>&1
aws s3api delete-bucket --bucket pol > /dev/null 2>&1 && fail "delete-bucket under a Deny" || pass "delete-bucket under a Deny"
aws s3api delete-bucket-policy --bucket pol > /dev/null 2>&1
aws s3api delete-bucket --bucket pol > /dev/null 2>&1 && pass "delete-bucket after it" || fail "delete-bucket after it"

# ACLs (ADR-0045): canned ACLs, grants and the document; what they open to anonymous requests; the block's ACL settings.
grants() { "$@" --query 'Grants[].[Grantee.ID,Grantee.URI,Permission]' --output text | tr '\t\n' ' ;'; }
everyone=http://acs.amazonaws.com/groups/global/AllUsers
aws s3api create-bucket --bucket acl > /dev/null 2>&1
aws s3api put-object --bucket acl --key a.txt --body pub.txt > /dev/null 2>&1
check "a new bucket's ACL" "$(grants aws s3api get-bucket-acl --bucket acl)" "cosmostore None FULL_CONTROL;"
check "a new object's ACL" "$(grants aws s3api get-object-acl --bucket acl --key a.txt)" "cosmostore None FULL_CONTROL;"
check "anonymous without an ACL" "$(anon "$AWS_ENDPOINT_URL/acl/a.txt")" 403
aws s3api put-object-acl --bucket acl --key a.txt --acl public-read > /dev/null 2>&1 || fail "put-object-acl"
check "get-object-acl" "$(grants aws s3api get-object-acl --bucket acl --key a.txt)" "cosmostore None FULL_CONTROL;None $everyone READ;"
check "anonymous read by the object's ACL" "$(anon "$AWS_ENDPOINT_URL/acl/a.txt") $(cat anon.out)" "200 public bytes"
check "the object's headers" "$(curl -s -I "$AWS_ENDPOINT_URL/acl/a.txt" | grep -ci 'x-amz-acl')" 0
check "anonymous ACL read" "$(anon "$AWS_ENDPOINT_URL/acl/a.txt?acl")" 403
check "anonymous list without the bucket's ACL" "$(anon "$AWS_ENDPOINT_URL/acl?list-type=2")" 403
aws s3api put-bucket-acl --bucket acl --acl public-read > /dev/null 2>&1 || fail "put-bucket-acl"
check "get-bucket-acl" "$(grants aws s3api get-bucket-acl --bucket acl)" "cosmostore None FULL_CONTROL;None $everyone READ;"
check "anonymous list by the bucket's ACL" "$(anon "$AWS_ENDPOINT_URL/acl?list-type=2")" 200
check "anonymous put under public-read" "$(anon -X PUT --data-binary @pub.txt "$AWS_ENDPOINT_URL/acl/x.txt")" 403
check "the status of a public ACL" "$(aws s3api get-bucket-policy-status --bucket acl --query PolicyStatus.IsPublic)" true
aws s3api put-bucket-acl --bucket acl --grant-full-control id=cosmostore --grant-write "uri=\"$everyone\"" > /dev/null 2>&1 || fail "put-bucket-acl with grants"
check "the grants" "$(grants aws s3api get-bucket-acl --bucket acl)" "cosmostore None FULL_CONTROL;None $everyone WRITE;"
check "anonymous put by a WRITE grant" "$(anon -X PUT --data-binary @pub.txt "$AWS_ENDPOINT_URL/acl/x.txt")" 200
check "anonymous list without READ" "$(anon "$AWS_ENDPOINT_URL/acl?list-type=2")" 403
check "the anonymous object is private" "$(anon "$AWS_ENDPOINT_URL/acl/x.txt")" 403
check "anonymous delete by it" "$(anon -X DELETE "$AWS_ENDPOINT_URL/acl/x.txt")" 204
aws s3api put-object --bucket acl --key b.txt --body pub.txt --acl public-read > /dev/null 2>&1 || fail "put-object with an ACL"
check "anonymous read of an object put public" "$(anon "$AWS_ENDPOINT_URL/acl/b.txt")" 200
aws s3api copy-object --bucket acl --key c.txt --copy-source acl/b.txt > /dev/null 2>&1
check "a copy is private" "$(anon "$AWS_ENDPOINT_URL/acl/c.txt")" 403
aws s3api copy-object --bucket acl --key d.txt --copy-source acl/b.txt --acl public-read > /dev/null 2>&1
check "a copy with its own ACL" "$(anon "$AWS_ENDPOINT_URL/acl/d.txt")" 200
printf '%s' '{"Statement": [{"Effect": "Deny", "Principal": "*", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::acl/d.txt"}]}' > deny-d.json
aws s3api put-bucket-policy --bucket acl --policy file://deny-d.json > /dev/null 2>&1
check "a Deny over the ACL" "$(anon "$AWS_ENDPOINT_URL/acl/d.txt")" 403
check "the ACL beside the Deny" "$(anon "$AWS_ENDPOINT_URL/acl/b.txt")" 200
aws s3api delete-bucket-policy --bucket acl > /dev/null 2>&1
aws s3api put-public-access-block --bucket acl --public-access-block-configuration IgnorePublicAcls=true > /dev/null 2>&1
check "anonymous read under IgnorePublicAcls" "$(anon "$AWS_ENDPOINT_URL/acl/b.txt")" 403
check "anonymous put under it" "$(anon -X PUT --data-binary @pub.txt "$AWS_ENDPOINT_URL/acl/y.txt")" 403
check "the status under it" "$(aws s3api get-bucket-policy-status --bucket acl --query PolicyStatus.IsPublic)" false
check "the ACL stays" "$(grants aws s3api get-object-acl --bucket acl --key b.txt)" "cosmostore None FULL_CONTROL;None $everyone READ;"
aws s3api put-public-access-block --bucket acl --public-access-block-configuration BlockPublicAcls=true > /dev/null 2>&1
check "anonymous read without IgnorePublicAcls" "$(anon "$AWS_ENDPOINT_URL/acl/b.txt")" 200
check "a public bucket ACL under BlockPublicAcls" "$(code s3api put-bucket-acl --bucket acl --acl public-read)" AccessDenied
check "a public object ACL under it" "$(code s3api put-object-acl --bucket acl --key a.txt --acl authenticated-read)" AccessDenied
check "a public object under it" "$(code s3api put-object --bucket acl --key e.txt --body pub.txt --acl public-read)" AccessDenied
aws s3api put-object-acl --bucket acl --key b.txt --acl private > /dev/null 2>&1 && pass "a private ACL under it" || fail "a private ACL under it"
check "anonymous read after private" "$(anon "$AWS_ENDPOINT_URL/acl/b.txt")" 403
aws s3api delete-public-access-block --bucket acl > /dev/null 2>&1
aws s3api put-bucket-acl --bucket acl --acl public-read > /dev/null 2>&1
check "a missing key, for a requester who may list" "$(anon "$AWS_ENDPOINT_URL/acl/missing.txt")" 404
aws s3api put-bucket-acl --bucket acl --acl private > /dev/null 2>&1
check "a missing key, for one who may not" "$(anon "$AWS_ENDPOINT_URL/acl/missing.txt")" 403
aws s3api put-bucket-acl --bucket acl --access-control-policy "{\"Owner\": {\"ID\": \"cosmostore\"}, \"Grants\": [{\"Grantee\": {\"Type\": \"CanonicalUser\", \"ID\": \"cosmostore\"}, \"Permission\": \"FULL_CONTROL\"}, {\"Grantee\": {\"Type\": \"Group\", \"URI\": \"$everyone\"}, \"Permission\": \"READ_ACP\"}]}" > /dev/null 2>&1 || fail "put-bucket-acl with a document"
check "the document's grants" "$(grants aws s3api get-bucket-acl --bucket acl)" "cosmostore None FULL_CONTROL;None $everyone READ_ACP;"
check "anonymous ACL read by READ_ACP" "$(anon "$AWS_ENDPOINT_URL/acl?acl")" 200
check "a grantee there is not" "$(code s3api put-bucket-acl --bucket acl --grant-read id=stranger)" InvalidArgument
check "a grantee by email" "$(code s3api put-bucket-acl --bucket acl --grant-read emailAddress=a@example.com)" UnresolvableGrantByEmailAddress
check "an owner there is not" "$(code s3api put-bucket-acl --bucket acl --access-control-policy '{"Owner": {"ID": "stranger"}, "Grants": []}')" InvalidArgument
check "an ACL on a missing key" "$(code s3api put-object-acl --bucket acl --key missing --acl private)" NoSuchKey
aws s3api create-bucket --bucket acl-made --acl public-read > /dev/null 2>&1
check "a bucket made public" "$(anon "$AWS_ENDPOINT_URL/acl-made?list-type=2")" 200
aws s3api delete-bucket --bucket acl-made > /dev/null 2>&1
aws s3 rm --recursive s3://acl/ > /dev/null 2>&1
aws s3api delete-bucket --bucket acl > /dev/null 2>&1 && pass "delete-bucket with an ACL" || fail "delete-bucket with an ACL"

# Object lock (ADR-0047): the bucket's configuration, retention and legal hold, what a locked version refuses, bypass.
aws s3api create-bucket --bucket lock --object-lock-enabled-for-bucket > /dev/null 2>&1 || fail "create-bucket with object lock"
check "versioning under object lock" "$(aws s3api get-bucket-versioning --bucket lock --query Status --output text)" Enabled
check "get-object-lock-configuration" "$(aws s3api get-object-lock-configuration --bucket lock --query ObjectLockConfiguration.ObjectLockEnabled --output text)" Enabled
check "no object lock configuration" "$(code s3api get-object-lock-configuration --bucket smoke)" ObjectLockConfigurationNotFoundError
check "object lock without versioning" "$(code s3api put-object-lock-configuration --bucket smoke --object-lock-configuration ObjectLockEnabled=Enabled)" InvalidBucketState
check "versioning suspended under object lock" "$(code s3api put-bucket-versioning --bucket lock --versioning-configuration Status=Suspended)" InvalidBucketState
check "a lock in a bucket without object lock" "$(code s3api put-object --bucket smoke --key held.txt --body pub.txt --object-lock-legal-hold-status ON)" InvalidRequest
lv=$(aws s3api put-object --bucket lock --key a.txt --body pub.txt --object-lock-mode GOVERNANCE --object-lock-retain-until-date 2040-01-01T00:00:00Z --query VersionId --output text)
check "get-object-retention" "$(aws s3api get-object-retention --bucket lock --key a.txt --query '[Retention.Mode,Retention.RetainUntilDate]' --output text | cut -c1-21)" "GOVERNANCE	2040-01-01"
check "the lock in a head" "$(aws s3api head-object --bucket lock --key a.txt --query ObjectLockMode --output text)" GOVERNANCE
check "a locked version" "$(code s3api delete-object --bucket lock --key a.txt --version-id "$lv")" AccessDenied
check "a locked version in delete-objects" "$(aws s3api delete-objects --bucket lock --delete '{"Objects":[{"Key":"a.txt","VersionId":"'"$lv"'"}]}' --query 'Errors[0].Code' --output text)" AccessDenied
check "a delete marker over it" "$(aws s3api delete-object --bucket lock --key a.txt --query DeleteMarker)" true
check "the version under the marker" "$(aws s3api get-object --bucket lock --key a.txt --version-id "$lv" got.txt > /dev/null 2>&1 && cat got.txt)" "public bytes"
check "a retention shortened" "$(code s3api put-object-retention --bucket lock --key a.txt --version-id "$lv" --retention Mode=GOVERNANCE,RetainUntilDate=2030-01-01T00:00:00Z)" AccessDenied
aws s3api put-object-retention --bucket lock --key a.txt --version-id "$lv" --retention Mode=GOVERNANCE,RetainUntilDate=2030-01-01T00:00:00Z --bypass-governance-retention > /dev/null 2>&1 && pass "shortened with a bypass" || fail "shortened with a bypass"
check "the retention after it" "$(aws s3api get-object-retention --bucket lock --key a.txt --version-id "$lv" --query Retention.RetainUntilDate --output text | cut -c1-10)" 2030-01-01
check "a retention in the past" "$(code s3api put-object-retention --bucket lock --key a.txt --version-id "$lv" --retention Mode=GOVERNANCE,RetainUntilDate=2020-01-01T00:00:00Z --bypass-governance-retention)" InvalidArgument
check "no legal hold yet" "$(aws s3api get-object-legal-hold --bucket lock --key a.txt --version-id "$lv" --query LegalHold.Status --output text)" OFF
aws s3api put-object-legal-hold --bucket lock --key a.txt --version-id "$lv" --legal-hold Status=ON > /dev/null 2>&1 || fail "put-object-legal-hold"
check "get-object-legal-hold" "$(aws s3api get-object-legal-hold --bucket lock --key a.txt --version-id "$lv" --query LegalHold.Status --output text)" ON
check "a held version, with a bypass" "$(code s3api delete-object --bucket lock --key a.txt --version-id "$lv" --bypass-governance-retention)" AccessDenied
aws s3api put-object-legal-hold --bucket lock --key a.txt --version-id "$lv" --legal-hold Status=OFF > /dev/null 2>&1
aws s3api delete-object --bucket lock --key a.txt --version-id "$lv" --bypass-governance-retention > /dev/null 2>&1 && pass "governance bypassed" || fail "governance bypassed"
check "the version is gone" "$(code s3api get-object --bucket lock --key a.txt --version-id "$lv" got.txt)" NoSuchVersion
aws s3api put-object-lock-configuration --bucket lock --object-lock-configuration 'ObjectLockEnabled=Enabled,Rule={DefaultRetention={Mode=GOVERNANCE,Days=1}}' > /dev/null 2>&1 || fail "put-object-lock-configuration"
check "the default retention" "$(aws s3api get-object-lock-configuration --bucket lock --query 'ObjectLockConfiguration.Rule.DefaultRetention.[Mode,Days]' --output text | tr '\t' ' ')" "GOVERNANCE 1"
dv=$(aws s3api put-object --bucket lock --key b.txt --body pub.txt --query VersionId --output text)
check "a new object's default retention" "$(aws s3api get-object-retention --bucket lock --key b.txt --query Retention.Mode --output text)" GOVERNANCE
check "the default keeps it" "$(code s3api delete-object --bucket lock --key b.txt --version-id "$dv")" AccessDenied
check "a period that is none" "$(code s3api put-object-lock-configuration --bucket lock --object-lock-configuration 'ObjectLockEnabled=Enabled,Rule={DefaultRetention={Mode=GOVERNANCE,Days=0}}')" InvalidRetentionPeriod
for kind in Versions DeleteMarkers; do
    aws s3api list-object-versions --bucket lock --query "$kind[].[Key,VersionId]" --output text | while read -r key id; do
        [ "$key" = None ] || aws s3api delete-object --bucket lock --key "$key" --version-id "$id" --bypass-governance-retention > /dev/null 2>&1
    done
done
aws s3api delete-bucket --bucket lock > /dev/null 2>&1 && pass "delete-bucket once nothing is locked" || fail "delete-bucket once nothing is locked"

# SSE-S3 on PutObject, GetObject and HeadObject (ADR-0046): sealed in 64 KiB chunks, opened whole, ranges too.
printf 'a sealed line of cosmostore\n' > sse.txt
check "SSE-S3 put" "$(aws s3api put-object --bucket smoke --key sse/small.txt --body sse.txt --server-side-encryption AES256 --query '[ServerSideEncryption,ETag]' --output text | tr '\t' ' ')" "AES256 \"$(md5 -q sse.txt 2>/dev/null || md5sum sse.txt | cut -d' ' -f1)\""
check "SSE-S3 head" "$(aws s3api head-object --bucket smoke --key sse/small.txt --query '[ServerSideEncryption,ContentLength]' --output text | tr '\t' ' ')" "AES256 $(wc -c < sse.txt | tr -d ' ')"
aws s3api get-object --bucket smoke --key sse/small.txt got.txt > /dev/null 2>&1
cmp -s got.txt sse.txt && pass "SSE-S3 get, inline" || fail "SSE-S3 get, inline"
head -c 300001 /dev/urandom > sse.bin
check "SSE-S3 put, in extents" "$(aws s3api put-object --bucket smoke --key sse/big.bin --body sse.bin --server-side-encryption AES256 --query ServerSideEncryption --output text)" AES256
aws s3api get-object --bucket smoke --key sse/big.bin got.bin > /dev/null 2>&1
cmp -s got.bin sse.bin && pass "SSE-S3 get, extents" || fail "SSE-S3 get, extents"
aws s3api get-object --bucket smoke --key sse/big.bin --range bytes=65530-131080 got.bin > /dev/null 2>&1
dd if=sse.bin of=want.bin bs=1 skip=65530 count=65551 2> /dev/null
cmp -s got.bin want.bin && pass "SSE-S3 range across chunks" || fail "SSE-S3 range across chunks"
aws s3api get-object --bucket smoke --key sse/big.bin --range bytes=-5 got.bin > /dev/null 2>&1
tail -c 5 sse.bin > want.bin
cmp -s got.bin want.bin && pass "SSE-S3 range at the end" || fail "SSE-S3 range at the end"
: > empty.bin
aws s3api put-object --bucket smoke --key sse/empty --body empty.bin --server-side-encryption AES256 > /dev/null 2>&1 || fail "SSE-S3 put, empty"
check "SSE-S3 empty" "$(aws s3api head-object --bucket smoke --key sse/empty --query ContentLength --output text)" 0
check "no plaintext on disk" "$(grep -rl 'a sealed line of cosmostore' "$work/store" | wc -l | tr -d ' ')" 0
# Copies (ADR-0046 §3): a sealed source opened, the copy stored as the request asks; never the source's envelope.
aws s3api copy-object --bucket smoke --key sse/copy --copy-source smoke/sse/small.txt > /dev/null 2>&1 || fail "copy of a sealed object"
check "a copy of a sealed object, in the clear" "$(aws s3api head-object --bucket smoke --key sse/copy --query ServerSideEncryption --output text)" None
aws s3api get-object --bucket smoke --key sse/copy got.txt > /dev/null 2>&1
cmp -s got.txt sse.txt && pass "the copy reads as its source" || fail "the copy reads as its source"
check "a copy sealed" "$(aws s3api copy-object --bucket smoke --key sse/copy2 --copy-source smoke/a/small.txt --server-side-encryption AES256 --query ServerSideEncryption --output text)" AES256
aws s3api get-object --bucket smoke --key sse/copy2 got.txt > /dev/null 2>&1
cmp -s got.txt small.txt && pass "a sealed copy reads" || fail "a sealed copy reads"
check "sealed again onto itself" "$(aws s3api copy-object --bucket smoke --key sse/big.bin --copy-source smoke/sse/big.bin --server-side-encryption AES256 --query ServerSideEncryption --output text)" AES256
aws s3api get-object --bucket smoke --key sse/big.bin got.bin > /dev/null 2>&1
cmp -s got.bin sse.bin && pass "sealed again, the same bytes" || fail "sealed again, the same bytes"
# SSE-S3 multipart: parts numbered 1 and 3, part 3 uploaded twice; each part under a key of its own (ADR-0046 §2).
head -c 5242880 /dev/urandom > p1.bin
head -c 70001 /dev/urandom > p3.bin
head -c 1000 /dev/urandom > p3old.bin
created=$(aws s3api create-multipart-upload --bucket smoke --key sse/mp --server-side-encryption AES256 --query '[UploadId,ServerSideEncryption]' --output text)
mpid=$(printf '%s' "$created" | cut -f1)
check "SSE-S3 create-multipart-upload" "$(printf '%s' "$created" | cut -f2)" AES256
check "SSE-S3 upload-part" "$(aws s3api upload-part --bucket smoke --key sse/mp --upload-id "$mpid" --part-number 1 --body p1.bin --query ServerSideEncryption --output text)" AES256
aws s3api upload-part --bucket smoke --key sse/mp --upload-id "$mpid" --part-number 3 --body p3old.bin > /dev/null 2>&1 || fail "SSE-S3 upload-part 3"
aws s3api upload-part --bucket smoke --key sse/mp --upload-id "$mpid" --part-number 3 --body p3.bin > /dev/null 2>&1 || fail "SSE-S3 upload-part 3 again"
aws s3api upload-part-copy --bucket smoke --key sse/mp --upload-id "$mpid" --part-number 2 --copy-source smoke/a/small.txt > /dev/null 2>&1 \
    && pass "a copy into a sealed upload" || fail "a copy into a sealed upload"
mpetag() { aws s3api list-parts --bucket smoke --key sse/mp --upload-id "$mpid" --query "Parts[?PartNumber==\`$1\`].ETag" --output text; }
mpparts=$(printf '{"Parts":[{"PartNumber":1,"ETag":%s},{"PartNumber":3,"ETag":%s}]}' "$(mpetag 1)" "$(mpetag 3)")
check "SSE-S3 complete" "$(aws s3api complete-multipart-upload --bucket smoke --key sse/mp --upload-id "$mpid" --multipart-upload "$mpparts" --query ServerSideEncryption --output text)" AES256
cat p1.bin p3.bin > mp.bin
aws s3api get-object --bucket smoke --key sse/mp got.bin > /dev/null 2>&1
cmp -s got.bin mp.bin && pass "SSE-S3 multipart get" || fail "SSE-S3 multipart get"
aws s3api get-object --bucket smoke --key sse/mp --range bytes=5242870-5242899 got.bin > /dev/null 2>&1
dd if=mp.bin of=want.bin bs=1 skip=5242870 count=30 2> /dev/null
cmp -s got.bin want.bin && pass "SSE-S3 range across parts" || fail "SSE-S3 range across parts"
aws s3api get-object --bucket smoke --key sse/mp --range bytes=$((5242880 + 65540))-$((5242880 + 65549)) got.bin > /dev/null 2>&1
dd if=mp.bin of=want.bin bs=1 skip=$((5242880 + 65540)) count=10 2> /dev/null
cmp -s got.bin want.bin && pass "SSE-S3 range inside a part, after its first chunk" || fail "SSE-S3 range inside a part, after its first chunk"
aws s3api get-object --bucket smoke --key sse/mp --part-number 2 got.bin > /dev/null 2>&1
cmp -s got.bin p3.bin && pass "SSE-S3 partNumber" || fail "SSE-S3 partNumber"
check "SSE-S3 multipart head" "$(aws s3api head-object --bucket smoke --key sse/mp --query '[ServerSideEncryption,ContentLength]' --output text | tr '\t' ' ')" "AES256 5312881"
head -c 20000000 /dev/urandom > cp.bin
aws s3 cp cp.bin s3://smoke/sse/cp.bin --sse AES256 > /dev/null 2>&1 || fail "SSE-S3 s3 cp, multipart"
aws s3 cp s3://smoke/sse/cp.bin got.bin > /dev/null 2>&1
cmp -s got.bin cp.bin && pass "SSE-S3 s3 cp, multipart, back" || fail "SSE-S3 s3 cp, multipart, back"
# A sealed multipart object copied: whole, and by parts whose ranges start inside its parts and cross them.
aws s3api copy-object --bucket smoke --key sse/mpcopy --copy-source smoke/sse/mp > /dev/null 2>&1 || fail "copy of a sealed multipart object"
aws s3api get-object --bucket smoke --key sse/mpcopy got.bin > /dev/null 2>&1
cmp -s got.bin mp.bin && pass "a sealed multipart object copied" || fail "a sealed multipart object copied"
cpid=$(aws s3api create-multipart-upload --bucket smoke --key sse/parts --server-side-encryption AES256 --query UploadId --output text)
aws s3api upload-part-copy --bucket smoke --key sse/parts --upload-id "$cpid" --part-number 1 --copy-source smoke/sse/mp --copy-source-range bytes=70000-5312879 > /dev/null 2>&1 || fail "upload-part-copy across a sealed object's parts"
aws s3api upload-part-copy --bucket smoke --key sse/parts --upload-id "$cpid" --part-number 2 --copy-source smoke/sse/mp --copy-source-range bytes=5242890-5312880 > /dev/null 2>&1 || fail "upload-part-copy inside a sealed part"
cpetag() { aws s3api list-parts --bucket smoke --key sse/parts --upload-id "$cpid" --query "Parts[?PartNumber==\`$1\`].ETag" --output text; }
cpparts=$(printf '{"Parts":[{"PartNumber":1,"ETag":%s},{"PartNumber":2,"ETag":%s}]}' "$(cpetag 1)" "$(cpetag 2)")
aws s3api complete-multipart-upload --bucket smoke --key sse/parts --upload-id "$cpid" --multipart-upload "$cpparts" > /dev/null 2>&1 || fail "complete the copied parts"
tail -c +70001 mp.bin | head -c 5242880 > want.bin
dd if=mp.bin bs=1 skip=5242890 2> /dev/null >> want.bin
aws s3api get-object --bucket smoke --key sse/parts got.bin > /dev/null 2>&1
cmp -s got.bin want.bin && pass "parts copied from a sealed object" || fail "parts copied from a sealed object"
# A bucket's default encryption (ADR-0046 §5).
aws s3api create-bucket --bucket enc > /dev/null 2>&1
check "no default encryption" "$(code s3api get-bucket-encryption --bucket enc)" ServerSideEncryptionConfigurationNotFoundError
aws s3api put-bucket-encryption --bucket enc --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' > /dev/null 2>&1 || fail "put-bucket-encryption"
check "get-bucket-encryption" "$(aws s3api get-bucket-encryption --bucket enc --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)" AES256
check "a default of SSE-KMS:DSSE" "$(code s3api put-bucket-encryption --bucket enc --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms:dsse"}}]}')" NotImplemented
check "a default of a KMS key there is not" "$(code s3api put-bucket-encryption --bucket enc --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"nobody"}}]}')" InvalidArgument
printf 'sealed by default in cosmostore\n' > dflt.txt
check "sealed by the default" "$(aws s3api put-object --bucket enc --key d.txt --body dflt.txt --query ServerSideEncryption --output text)" AES256
aws s3api get-object --bucket enc --key d.txt got.txt > /dev/null 2>&1
cmp -s got.txt dflt.txt && pass "read under the default" || fail "read under the default"
check "a copy into it sealed by the default" "$(aws s3api copy-object --bucket enc --key c.txt --copy-source smoke/a/small.txt --query ServerSideEncryption --output text)" AES256
encid=$(aws s3api create-multipart-upload --bucket enc --key m --query '[UploadId,ServerSideEncryption]' --output text)
check "an upload into it sealed by the default" "$(printf '%s' "$encid" | cut -f2)" AES256
aws s3api abort-multipart-upload --bucket enc --key m --upload-id "$(printf '%s' "$encid" | cut -f1)" > /dev/null 2>&1
check "the default's plaintext not on disk" "$(grep -rl 'sealed by default in cosmostore' "$work/store" | wc -l | tr -d ' ')" 0
aws s3api delete-bucket-encryption --bucket enc > /dev/null 2>&1 || fail "delete-bucket-encryption"
check "no default after delete" "$(aws s3api put-object --bucket enc --key e.txt --body dflt.txt --query ServerSideEncryption --output text)" None
aws s3api put-bucket-encryption --bucket enc --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"orders"}}]}' > /dev/null 2>&1 || fail "a default of SSE-KMS"
check "get a default of SSE-KMS" "$(aws s3api get-bucket-encryption --bucket enc --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.[SSEAlgorithm,KMSMasterKeyID]' --output text | tr '\t' ' ')" "aws:kms orders"
check "sealed by a default of SSE-KMS" "$(aws s3api put-object --bucket enc --key k.txt --body dflt.txt --query '[ServerSideEncryption,SSEKMSKeyId]' --output text | tr '\t' ' ')" "aws:kms orders"
aws s3 rm --recursive s3://enc/ > /dev/null 2>&1
aws s3api delete-bucket --bucket enc > /dev/null 2>&1 || fail "delete the bucket with a default"
# SSE-KMS (ADR-0055): named keys of the KMS key file, the first by default.
check "SSE-KMS put, the default key" "$(aws s3api put-object --bucket smoke --key sse/kms --body sse.txt --server-side-encryption aws:kms --query '[ServerSideEncryption,SSEKMSKeyId]' --output text | tr '\t' ' ')" "aws:kms app-default"
check "SSE-KMS put, a named key" "$(aws s3api put-object --bucket smoke --key sse/kms2 --body sse.bin --server-side-encryption aws:kms --ssekms-key-id arn:aws:kms:us-east-1:000000000000:key/orders --query SSEKMSKeyId --output text)" orders
check "SSE-KMS head" "$(aws s3api head-object --bucket smoke --key sse/kms2 --query '[ServerSideEncryption,SSEKMSKeyId,ContentLength]' --output text | tr '\t' ' ')" "aws:kms orders 300001"
aws s3api get-object --bucket smoke --key sse/kms2 got.bin > /dev/null 2>&1
cmp -s got.bin sse.bin && pass "SSE-KMS get" || fail "SSE-KMS get"
aws s3api get-object --bucket smoke --key sse/kms2 --range bytes=70000-70009 got.bin > /dev/null 2>&1
dd if=sse.bin of=want.bin bs=1 skip=70000 count=10 2> /dev/null
cmp -s got.bin want.bin && pass "SSE-KMS range" || fail "SSE-KMS range"
check "SSE-KMS's ETag is not the MD5" "$([ "$(aws s3api head-object --bucket smoke --key sse/kms --query ETag --output text)" = "\"$(md5 -q sse.txt 2>/dev/null || md5sum sse.txt | cut -d' ' -f1)\"" ] && echo md5 || echo other)" other
check "SSE-KMS, a key there is not" "$(code s3api put-object --bucket smoke --key sse/kms3 --body sse.txt --server-side-encryption aws:kms --ssekms-key-id nobody)" InvalidArgument
check "SSE-KMS:DSSE" "$(code s3api put-object --bucket smoke --key sse/kms3 --body sse.txt --server-side-encryption aws:kms:dsse)" NotImplemented
# SSE-KMS's encryption context (ADR-0090 §6): base64 JSON, kept under the data key's seal and returned.
ctx=$(printf '{"team":"blue"}' | base64)
# PutObject's answer carries the context, as botocore models it (HeadObject's and GetObject's do not).
check "SSE-KMS with an encryption context, returned" "$(aws s3api put-object --bucket smoke --key sse/ctx --body sse.txt --server-side-encryption aws:kms --ssekms-encryption-context "$ctx" --query '[SSEKMSKeyId,SSEKMSEncryptionContext]' --output text 2>&1 | tr '\t' ' ')" "app-default $ctx"
aws s3api get-object --bucket smoke --key sse/ctx got.txt > /dev/null 2>&1
cmp -s got.txt sse.txt && pass "and read" || fail "and read"
check "a context that is not JSON refused" "$(code s3api put-object --bucket smoke --key sse/ctx2 --body sse.txt --server-side-encryption aws:kms --ssekms-encryption-context bm90IGpzb24=)" InvalidArgument
aws s3 cp --only-show-errors cp.bin s3://smoke/sse/kmsmp.bin --sse aws:kms --sse-kms-key-id orders > /dev/null 2>&1 || fail "SSE-KMS multipart cp"
aws s3 cp --only-show-errors s3://smoke/sse/kmsmp.bin got.bin > /dev/null 2>&1
cmp -s got.bin cp.bin && pass "SSE-KMS multipart both ways" || fail "SSE-KMS multipart both ways"
check "SSE-KMS multipart head" "$(aws s3api head-object --bucket smoke --key sse/kmsmp.bin --query SSEKMSKeyId --output text)" orders
check "SSE-KMS copied to SSE-S3" "$(aws s3api copy-object --bucket smoke --key sse/kmscopy --copy-source smoke/sse/kms2 --server-side-encryption AES256 --query ServerSideEncryption --output text)" AES256
aws s3api get-object --bucket smoke --key sse/kmscopy got.bin > /dev/null 2>&1
cmp -s got.bin sse.bin && pass "SSE-KMS copied reads" || fail "SSE-KMS copied reads"
check "copied into SSE-KMS" "$(aws s3api copy-object --bucket smoke --key sse/tokms --copy-source smoke/a/small.txt --server-side-encryption aws:kms --ssekms-key-id orders --query SSEKMSKeyId --output text)" orders
# SSE-C only over TLS (ADR-0046 §6; tools/tls_smoke.sh serves it): over plain HTTP it is refused, not stored.
check "SSE-C over HTTP" "$(code s3api put-object --bucket smoke --key sse.txt --body pub.txt --sse-customer-algorithm AES256 --sse-customer-key 01234567890123456789012345678901)" InvalidRequest
check "a read with a key over HTTP" "$(code s3api get-object --bucket smoke --key sse.txt --sse-customer-algorithm AES256 --sse-customer-key 01234567890123456789012345678901 got.txt)" InvalidRequest
check "nothing stored" "$(aws s3api list-objects-v2 --bucket smoke --prefix sse.txt --query 'Contents[].Key' --output text)" None

# CORS (ADR-0049): the rules, a browser's preflight, and the fields on answers to requests that name an origin.
cors() { curl -s -o /dev/null -D cors.out "$@"; printf '%s %s %s' "$(sed -n '1s/^HTTP[^ ]* \([0-9]*\).*/\1/p' cors.out)" "$(sed -n 's/^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: *//p' cors.out | tr -d '\r')" "$(sed -n 's/^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Mm]ethods: *//p' cors.out | tr -d '\r')"; }
corsfield() { sed -n "s/^$1: *//Ip" cors.out | tr -d '\r'; }
aws s3api create-bucket --bucket cors --acl public-read > /dev/null 2>&1
aws s3api put-object --bucket cors --key a.txt --body pub.txt --acl public-read > /dev/null 2>&1
check "no CORS rules" "$(code s3api get-bucket-cors --bucket cors)" NoSuchCORSConfiguration
check "a preflight without rules" "$(cors -X OPTIONS -H 'Origin: https://app.example' -H 'Access-Control-Request-Method: GET' "$AWS_ENDPOINT_URL/cors/a.txt")" "403  "
aws s3api put-bucket-cors --bucket cors --cors-configuration '{"CORSRules":[{"ID":"site","AllowedOrigins":["https://*.example"],"AllowedMethods":["GET","HEAD"],"AllowedHeaders":["x-amz-*","content-type"],"ExposeHeaders":["ETag","x-amz-version-id"],"MaxAgeSeconds":600},{"AllowedOrigins":["*"],"AllowedMethods":["PUT"]}]}' > /dev/null 2>&1 || fail "put-bucket-cors"
check "get-bucket-cors" "$(aws s3api get-bucket-cors --bucket cors --query 'CORSRules[0].[ID,AllowedOrigins[0],length(AllowedMethods),AllowedHeaders[0],ExposeHeaders[1],MaxAgeSeconds]' --output text | tr '\t' ' ')" "site https://*.example 2 x-amz-* x-amz-version-id 600"
check "a preflight a rule allows" "$(cors -X OPTIONS -H 'Origin: https://app.example' -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: X-Amz-Date, Content-Type' "$AWS_ENDPOINT_URL/cors/a.txt")" "200 https://app.example GET"
check "its other fields" "$(corsfield access-control-allow-headers)|$(corsfield access-control-max-age)|$(corsfield access-control-expose-headers)|$(corsfield access-control-allow-credentials)" "X-Amz-Date, Content-Type|600|ETag, x-amz-version-id|true"
check "a preflight for a header it does not allow" "$(cors -X OPTIONS -H 'Origin: https://app.example' -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: authorization' "$AWS_ENDPOINT_URL/cors/a.txt")" "403  "
check "a preflight from another origin" "$(cors -X OPTIONS -H 'Origin: https://app.other' -H 'Access-Control-Request-Method: GET' "$AWS_ENDPOINT_URL/cors/a.txt")" "403  "
check "a preflight by the rule for any origin" "$(cors -X OPTIONS -H 'Origin: https://app.other' -H 'Access-Control-Request-Method: PUT' "$AWS_ENDPOINT_URL/cors/a.txt")" "200 * PUT"
check "a preflight for a method no rule has" "$(cors -X OPTIONS -H 'Origin: https://app.example' -H 'Access-Control-Request-Method: DELETE' "$AWS_ENDPOINT_URL/cors/a.txt")" "403  "
check "a preflight without an origin" "$(cors -X OPTIONS -H 'Access-Control-Request-Method: GET' "$AWS_ENDPOINT_URL/cors/a.txt")" "400  "
check "a preflight without a method" "$(cors -X OPTIONS -H 'Origin: https://app.example' "$AWS_ENDPOINT_URL/cors/a.txt")" "400  "
check "a read that names its origin" "$(cors -H 'Origin: https://app.example' "$AWS_ENDPOINT_URL/cors/a.txt")" "200 https://app.example GET"
check "what a script may read of it" "$(corsfield access-control-expose-headers)" "ETag, x-amz-version-id"
check "a read from another origin" "$(cors -H 'Origin: https://app.other' "$AWS_ENDPOINT_URL/cors/a.txt")" "200  "
check "a read without an origin" "$(cors "$AWS_ENDPOINT_URL/cors/a.txt")" "200  "
check "an error that names its origin" "$(cors -H 'Origin: https://app.example' "$AWS_ENDPOINT_URL/cors/missing.txt")" "404 https://app.example GET"
check "a method the CLI's S3 has no CORS for" "$(code s3api put-bucket-cors --bucket cors --cors-configuration '{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["PATCH"]}]}')" InvalidRequest
aws s3api delete-bucket-cors --bucket cors > /dev/null 2>&1 || fail "delete-bucket-cors"
check "no CORS rules again" "$(code s3api get-bucket-cors --bucket cors)" NoSuchCORSConfiguration
check "a read after the rules are gone" "$(cors -H 'Origin: https://app.example' "$AWS_ENDPOINT_URL/cors/a.txt")" "200  "
aws s3 rm --recursive s3://cors/ > /dev/null 2>&1
aws s3api delete-bucket --bucket cors > /dev/null 2>&1 && pass "delete-bucket after CORS" || fail "delete-bucket after CORS"

# Event notifications (ADR-0048): the rules, events at a webhook, and none lost while it is down or over a kill.
events() { wc -l < hook.out | tr -d ' '; }
# Up to 35 s: a delivery backs off 1, 2, 4, 8, 16 s while the webhook is down (DELIVERY_RETRY_MS), so the one that
# finds it back can come up to 16 s after it is; on a slow runner the wait must cover that.
wait_events() { n=0; while [ "$(events)" -lt "$1" ] && [ "$n" -lt 350 ]; do sleep 0.1; n=$((n + 1)); done; events; }
event() { tail -1 hook.out | python3 -c 'import json,sys; r=json.load(sys.stdin)["Records"][0]; o=r["s3"]["object"]; print(r["eventName"], r["s3"]["bucket"]["name"], o["key"], o.get("size"), r["s3"]["configurationId"])'; }
stat() { aws s3api get-object --bucket _cosmostore --key stats stats.json > /dev/null 2>&1; python3 -c 'import json,sys; print(json.load(open("stats.json"))[sys.argv[1]])' "$1"; }
rules() { aws s3api put-bucket-notification-configuration --bucket notify --notification-configuration "$1"; }
aws s3api create-bucket --bucket notify > /dev/null 2>&1
check "no notification rules" "$(aws s3api get-bucket-notification-configuration --bucket notify --query QueueConfigurations)" null
check "a target serve was not given" "$(code s3api put-bucket-notification-configuration --bucket notify --notification-configuration '{"QueueConfigurations":[{"QueueArn":"arn:cosmostore:sqs::nowhere:webhook","Events":["s3:ObjectCreated:*"]}]}')" InvalidArgument
check "a topic" "$(code s3api put-bucket-notification-configuration --bucket notify --notification-configuration '{"TopicConfigurations":[{"TopicArn":"arn:aws:sns:us-east-1:1:t","Events":["s3:ObjectCreated:*"]}]}')" NotImplemented
check "an event the store cannot tell apart" "$(code s3api put-bucket-notification-configuration --bucket notify --notification-configuration '{"QueueConfigurations":[{"QueueArn":"arn:cosmostore:sqs::hook:webhook","Events":["s3:ObjectCreated:Copy"]}]}')" NotImplemented
rules '{"QueueConfigurations":[{"Id":"logs","QueueArn":"arn:cosmostore:sqs::hook:webhook","Events":["s3:ObjectCreated:*","s3:ObjectRemoved:*"],"Filter":{"Key":{"FilterRules":[{"Name":"prefix","Value":"logs/"},{"Name":"suffix","Value":".txt"}]}}}]}' > /dev/null 2>&1 || fail "put-bucket-notification-configuration"
check "get-bucket-notification-configuration" "$(aws s3api get-bucket-notification-configuration --bucket notify --query 'QueueConfigurations[0].[Id,QueueArn,length(Events),Filter.Key.FilterRules[0].Value,Filter.Key.FilterRules[1].Value]' --output text | tr '\t' ' ')" "logs arn:cosmostore:sqs::hook:webhook 2 logs/ .txt"
aws s3api put-object --bucket notify --key "logs/a b.txt" --body pub.txt > /dev/null 2>&1
aws s3api put-object --bucket notify --key logs/a.bin --body pub.txt > /dev/null 2>&1
aws s3api put-object --bucket notify --key other/a.txt --body pub.txt > /dev/null 2>&1
check "an event at the webhook" "$(wait_events 1)" 1
check "the event" "$(event)" "ObjectCreated:Put notify logs/a%20b.txt 12 logs"
aws s3api delete-object --bucket notify --key "logs/a b.txt" > /dev/null 2>&1
check "a delete's event" "$(wait_events 2) $(event)" "2 ObjectRemoved:Delete notify logs/a%20b.txt None logs"
check "only the keys of the rule" "$(sleep 1; events)" 2
# The webhook goes down: the event waits; the server is killed: it still waits; both come back: it arrives.
kill "$hook"
wait "$hook" 2> /dev/null
aws s3api put-object --bucket notify --key logs/kept.txt --body pub.txt > /dev/null 2>&1
sleep 2
check "an event waits while the webhook is down" "$(stat eventsPending) $(events)" "1 2"
kill -9 "$server"
wait "$server" 2> /dev/null
start_server
check "it waits over a kill" "$(stat eventsPending)" 1
start_hook
check "delivered once the webhook is back" "$(wait_events 3) $(event)" "3 ObjectCreated:Put notify logs/kept.txt 12 logs"
check "nothing waits" "$(sleep 1; stat eventsPending) $(stat eventsDropped)" "0 0"
rules '{}' > /dev/null 2>&1 || fail "notification rules taken off"
aws s3api put-object --bucket notify --key logs/after.txt --body pub.txt > /dev/null 2>&1
check "no rules, no events" "$(sleep 1; events)" 3
aws s3 rm --recursive s3://notify/ > /dev/null 2>&1
aws s3api delete-bucket --bucket notify > /dev/null 2>&1 && pass "delete-bucket after notifications" || fail "delete-bucket after notifications"
# A restore's events (ADR-0106 §4): asked, its copy ready (4 s, an hour being a second here), and its copy expired
# (a day of 24 s, rounded up to the next: up to 48 s), each once, raised by the upkeep (2 s) as their times come.
aws s3api create-bucket --bucket notify-r > /dev/null 2>&1
aws s3api put-bucket-notification-configuration --bucket notify-r --notification-configuration '{"QueueConfigurations":[{"Id":"restores","QueueArn":"arn:cosmostore:sqs::hook:webhook","Events":["s3:ObjectRestore:*"]}]}' > /dev/null 2>&1
check "restore events in the rules" "$(aws s3api get-bucket-notification-configuration --bucket notify-r --query 'QueueConfigurations[0].Events[0]' --output text 2>&1)" "s3:ObjectRestore:*"
aws s3api put-object --bucket notify-r --key cold --body pub.txt --storage-class GLACIER > /dev/null 2>&1
check "no event for the write" "$(sleep 1; events)" 3
aws s3api restore-object --bucket notify-r --key cold --restore-request '{"Days":1,"GlacierJobParameters":{"Tier":"Standard"}}' > /dev/null 2>&1
check "a restore asked: :Post" "$(wait_events 4) $(event)" "4 ObjectRestore:Post notify-r cold 12 restores"
check "its copy ready: :Completed" "$(wait_events 5) $(event)" "5 ObjectRestore:Completed notify-r cold 12 restores"
n=0; while [ "$(events)" -lt 6 ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
check "its copy expired: :Delete" "$(events) $(event)" "6 ObjectRestore:Delete notify-r cold 12 restores"
check "each once" "$(sleep 3; events)" 6
aws s3 rm --recursive s3://notify-r/ > /dev/null 2>&1
aws s3api delete-bucket --bucket notify-r > /dev/null 2>&1

# Bucket quotas (ADR-0052): `?quota` is not an S3 call, so it is sent presigned, with curl.
quota() { curl -s -o quota.out -w '%{http_code}' -X "$1" ${3:+--data-binary "$3"} "$(python3 -I "$here/s3_raw.py" presign "$AWS_ENDPOINT_URL" "$1" "$2" "" 60 quota)"; }
quotaxml() { tr -d '\n' < quota.out | sed 's/.*<MaxBytes>//; s/<\/Objects>.*//'; }
aws s3api create-bucket --bucket quota > /dev/null 2>&1
printf 1234 > four.txt
check "a bucket's use without a quota" "$(quota GET quota) $(quotaxml)" "200 0</MaxBytes><MaxObjects>0</MaxObjects><Bytes>0</Bytes><Objects>0"
check "a quota is put" "$(quota PUT quota '<Quota><MaxBytes>20</MaxBytes><MaxObjects>2</MaxObjects></Quota>')" 200
aws s3api put-object --bucket quota --key a --body pub.txt > /dev/null 2>&1 || fail "a write within the quota"
check "a write past the bytes" "$(code s3api put-object --bucket quota --key b --body pub.txt)" QuotaExceeded
aws s3api put-object --bucket quota --key b --body four.txt > /dev/null 2>&1 || fail "a smaller write"
check "a write past the count" "$(code s3api put-object --bucket quota --key c --body four.txt)" QuotaExceeded
aws s3api put-object --bucket quota --key a --body four.txt > /dev/null 2>&1 && pass "an overwrite at the count" || fail "an overwrite at the count"
check "a copy past the count" "$(code s3api copy-object --bucket quota --key c --copy-source quota/a)" QuotaExceeded
check "the limits and the use" "$(quota GET quota) $(quotaxml)" "200 20</MaxBytes><MaxObjects>2</MaxObjects><Bytes>8</Bytes><Objects>2"
check "a quota without a limit" "$(quota PUT quota '<Quota></Quota>')" 400
# The admin CLI (ADR-0054): the same calls, signed by `cosmostore admin` with the credentials file's first key.
adm() { "$bin" admin "$AWS_ENDPOINT_URL" credentials "$@"; }
check "admin stats" "$(adm stats | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["objects"] > 0, "rateLimited" in d, "eventsPending" in d)')" "True True True"
check "admin buckets" "$(adm buckets | python3 -I -c 'import json,sys; b={x["name"]: x for x in json.load(sys.stdin)["buckets"]}; q=b["quota"]; print(q["bytes"], q["objects"], q["maxBytes"], q["maxObjects"], q["versioning"], b["smoke"]["objects"] > 0)')" "8 2 20 2 Off True"
check "admin quota, read" "$(adm quota quota | tr -d '\n' | sed 's/.*<MaxBytes>//; s/<\/Objects>.*//')" "20</MaxBytes><MaxObjects>2</MaxObjects><Bytes>8</Bytes><Objects>2"
adm quota quota 30 0 > /dev/null 2>&1 && pass "admin quota, set" || fail "admin quota, set"
check "the quota it set" "$(quota GET quota) $(quotaxml)" "200 30</MaxBytes><MaxObjects>0</MaxObjects><Bytes>8</Bytes><Objects>2"
check "admin on a bucket that is not there" "$(adm quota no-such-bucket 2>&1 > /dev/null | sed -n 's/.*<Code>\(.*\)<\/Code>.*/\1/p'); $?" "NoSuchBucket; 0"
echo "$AWS_ACCESS_KEY_ID wrong/secret" > wrong.credentials
check "admin with a wrong secret" "$("$bin" admin "$AWS_ENDPOINT_URL" wrong.credentials stats 2>&1 > /dev/null | sed -n 's/.*<Code>\(.*\)<\/Code>.*/\1/p')" SignatureDoesNotMatch
"$bin" admin "$AWS_ENDPOINT_URL" wrong.credentials stats > /dev/null 2>&1; check "its exit status" "$?" 1
adm nonsense > /dev/null 2>&1; check "admin with a command there is not" "$?" 2
"$bin" admin http://127.0.0.1:1 credentials stats > /dev/null 2>&1; check "admin with no server" "$?" 1
adm quota quota 20 2 > /dev/null 2>&1
check "an anonymous quota read" "$(anon "$AWS_ENDPOINT_URL/quota?quota")" 403
aws s3api delete-object --bucket quota --key b > /dev/null 2>&1
aws s3api put-object --bucket quota --key c --body four.txt > /dev/null 2>&1 && pass "a write after a delete" || fail "a write after a delete"
check "the quota is taken off" "$(quota DELETE quota)" 204
aws s3api put-object --bucket quota --key d --body pub.txt > /dev/null 2>&1 && pass "a write without a quota" || fail "a write without a quota"
check "the use after it" "$(quota GET quota) $(quotaxml)" "200 0</MaxBytes><MaxObjects>0</MaxObjects><Bytes>20</Bytes><Objects>3"
aws s3 rm --recursive s3://quota/ > /dev/null 2>&1
aws s3api delete-bucket --bucket quota > /dev/null 2>&1 && pass "delete-bucket after a quota" || fail "delete-bucket after a quota"

# The notification targets file reloaded (ADR-0096 §5): a target added is taken in a configuration, without a
# restart, and one removed is not.
cp "$work/targets" "$work/targets.kept"
printf 'later http://127.0.0.1:%s/later\n' "$hookport" >> "$work/targets"
sleep 4
grep -q "notification targets file reloaded: 2 targets" "$work/server.log" && pass "a notification target added, without a restart" || fail "a notification target added, without a restart"
aws s3api create-bucket --bucket reload-notify > /dev/null 2>&1
aws s3api put-bucket-notification-configuration --bucket reload-notify --notification-configuration '{"QueueConfigurations":[{"QueueArn":"arn:cosmostore:sqs::later:webhook","Events":["s3:ObjectCreated:*"]}]}' > /dev/null 2>&1 && pass "a configuration naming the target added" || fail "a configuration naming the target added"
cp "$work/targets.kept" "$work/targets"
sleep 4
check "a configuration naming a target removed" "$(code s3api put-bucket-notification-configuration --bucket reload-notify --notification-configuration '{"QueueConfigurations":[{"QueueArn":"arn:cosmostore:sqs::later:webhook","Events":["s3:ObjectCreated:*"]}]}')" InvalidArgument
aws s3api put-bucket-notification-configuration --bucket reload-notify --notification-configuration '{}' > /dev/null 2>&1
aws s3api delete-bucket --bucket reload-notify > /dev/null 2>&1

# Key rotation without a restart or a re-seal (ADR-0096 §3, ADR-0100): a key put first seals what is new, and the
# re-wrap pass moves what the old keys sealed under it, a batch per upkeep round (2 s), the bytes untouched. Once the
# stats count none under the old key, its removal is taken; the key in use cannot be removed, nor given new bytes.
sealed() { aws s3api get-object --bucket _cosmostore --key stats "$work/stats.json" > /dev/null 2>&1; python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["sealedByKey"]["s3"].get(sys.argv[2]); print(v)' "$work/stats.json" "$1"; }
check "the versions under k2 before" "$([ "$(sealed k2)" -gt 0 ] && echo some)" some
cp "$work/sse.keys" "$work/sse.keys.kept"
{ printf 'k3 %s\n' "$(head -c 32 /dev/urandom | base64)"; cat "$work/sse.keys.kept"; } > "$work/sse.keys"
sleep 4
grep -q "SSE key file reloaded: 3 keys" "$work/server.log" && pass "an SSE key added, without a restart" || fail "an SSE key added, without a restart"
check "an SSE-S3 put after the key added" "$(aws s3api put-object --bucket smoke --key sse/after-k3.txt --body sse.txt --server-side-encryption AES256 --query ServerSideEncryption --output text)" AES256
check "its read" "$(aws s3api get-object --bucket smoke --key sse/after-k3.txt "$work/k3.out" > /dev/null 2>&1 && cmp -s sse.txt "$work/k3.out" && echo same)" same
for i in $(seq 1 30); do [ "$(sealed k2)" = 0 ] && [ "$(sealed k1)" = 0 ] && break; sleep 1; done
check "the old keys' versions re-wrapped under k3" "$(sealed k2) $(sealed k1)" "0 0"
grep -q "re-wrapped [0-9]* versions under SSE key k3" "$work/server.log" && pass "the re-wrap logged" || fail "the re-wrap logged"
etag_after=$(aws s3api head-object --bucket smoke --key sse/big.bin --query ETag --output text)
check "a re-wrapped version reads, its bytes untouched" "$(aws s3api get-object --bucket smoke --key sse/small.txt "$work/k2.out" > /dev/null 2>&1 && cmp -s sse.txt "$work/k2.out" && echo same)" same
check "a re-wrapped version in extents reads" "$(aws s3api get-object --bucket smoke --key sse/big.bin "$work/big.out" > /dev/null 2>&1 && cmp -s sse.bin "$work/big.out" && echo same)" same
# The old keys removed: taken, as nothing needs them now.
grep '^k3 ' "$work/sse.keys" > "$work/sse.keys.next" && mv "$work/sse.keys.next" "$work/sse.keys"
sleep 4
grep -q "SSE key file reloaded: 1 keys" "$work/server.log" && pass "the old keys removed, without a restart" || fail "the old keys removed, without a restart"
check "and every version still reads" "$(aws s3api get-object --bucket smoke --key sse/big.bin "$work/big.out" > /dev/null 2>&1 && cmp -s sse.bin "$work/big.out" && echo same)" same
check "its ETag as it was" "$(aws s3api head-object --bucket smoke --key sse/big.bin --query ETag --output text)" "$etag_after"
# The key in use: its removal refused, and new bytes under its id refused.
cp "$work/sse.keys" "$work/sse.keys.k3"
printf 'k4 %s\n' "$(head -c 32 /dev/urandom | base64)" > "$work/sse.keys"
sleep 4
grep -q "SSE key file reload refused: [0-9]* versions, uploads or bucket encryption configurations still need the key it removes or changes (k3)" "$work/server.log" && pass "removing the key in use refused" || fail "removing the key in use refused"
printf 'k3 %s\n' "$(head -c 32 /dev/urandom | base64)" > "$work/sse.keys"
sleep 4
check "new bytes under the key in use refused" "$(grep -c "SSE key file reload refused: [0-9]* versions, uploads or bucket encryption configurations still need the key it removes or changes (k3)" "$work/server.log")" 2
cp "$work/sse.keys.k3" "$work/sse.keys"
sleep 4

# The IAM API (ADR-0104): a user made, given a key and a policy; its key live within an upkeep round (2 s).
check "iam create-user" "$(aws iam create-user --user-name dev --query User.UserName --output text 2>&1)" dev
check "a name twice" "$(code iam create-user --user-name dev)" EntityAlreadyExists
devkey=$(aws iam create-access-key --user-name dev --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text 2>&1)
devid=$(echo "$devkey" | cut -f1); devsecret=$(echo "$devkey" | cut -f2)
check "a key made" "$(echo "$devid" | cut -c1-4)" AKIA
aws iam put-user-policy --user-name dev --policy-name list-smoke --policy-document '{"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::smoke"}}' > /dev/null 2>&1 && pass "iam put-user-policy" || fail "iam put-user-policy"
check "its policy read back" "$(aws iam get-user-policy --user-name dev --policy-name list-smoke --query 'PolicyDocument.Statement.Action' --output text 2>&1)" s3:ListBucket
check "a policy not taken" "$(code iam put-user-policy --user-name dev --policy-name bad --policy-document '{"Statement":"nope"}')" MalformedPolicyDocument
check "nor a policy name IAM does not take" "$(code iam put-user-policy --user-name dev --policy-name 'a/b' --policy-document '{"Statement":{"Effect":"Allow","Action":"s3:ListBucket","Resource":"*"}}')" ValidationError
# ListUsers allowed on itself only: a list is about every user, so still refused (the M19 exit review).
aws iam put-user-policy --user-name dev --policy-name self-only --policy-document '{"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"iam:ListUsers","Resource":"arn:aws:iam::000000000000:user/dev"}}' > /dev/null 2>&1
check "listed" "$(aws iam list-users --query 'Users[?UserName==`dev`].UserName' --output text 2>&1)" dev
sleep 3
dev() { ( export AWS_ACCESS_KEY_ID="$devid" AWS_SECRET_ACCESS_KEY="$devsecret"; "$@" ); }
check "its key lists what its policy allows" "$(dev aws s3api list-objects-v2 --bucket smoke --max-keys 1 --query KeyCount --output text 2>&1)" 1
check "and no more" "$(dev code s3api put-object --bucket smoke --key iam.txt --body sse.txt)" AccessDenied
check "nor lists the users with a policy on itself" "$(dev code iam list-users)" AccessDenied
aws iam update-access-key --user-name dev --access-key-id "$devid" --status Inactive > /dev/null 2>&1
sleep 3
check "an inactive key refused" "$(dev code s3api list-objects-v2 --bucket smoke)" InvalidAccessKeyId
check "a user with keys is not deleted" "$(code iam delete-user --user-name dev)" DeleteConflict
aws iam delete-access-key --user-name dev --access-key-id "$devid" > /dev/null 2>&1
aws iam delete-user-policy --user-name dev --policy-name list-smoke > /dev/null 2>&1
aws iam delete-user-policy --user-name dev --policy-name self-only > /dev/null 2>&1
aws iam delete-user --user-name dev > /dev/null 2>&1 && pass "iam delete-user" || fail "iam delete-user"
check "gone" "$(code iam get-user --user-name dev)" NoSuchEntity
# IAM roles (ADR-0104 §1, §7): one made with a trust policy naming the account, given a policy, assumed through STS
# within a round; one whose trust names someone else, not assumed; a roles file's name not made again.
trustroot='{"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::000000000000:root"},"Action":"sts:AssumeRole"}}'
check "iam create-role" "$(aws iam create-role --role-name deployer --assume-role-policy-document "$trustroot" --query Role.RoleName --output text 2>&1)" deployer
check "a roles file's name not made again" "$(code iam create-role --role-name reader --assume-role-policy-document "$trustroot")" EntityAlreadyExists
aws iam put-role-policy --role-name deployer --policy-name list --policy-document '{"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::smoke"}}' > /dev/null 2>&1 && pass "iam put-role-policy" || fail "iam put-role-policy"
check "its trust read back" "$(aws iam get-role --role-name deployer --query 'Role.AssumeRolePolicyDocument.Statement.Principal.AWS' --output text 2>&1)" "arn:aws:iam::000000000000:root"
# A trust policy with what it cannot decide (a Condition, NotPrincipal, a wildcard action) is refused, not widened.
check "a trust policy with a Condition refused" "$(code iam create-role --role-name cond --assume-role-policy-document '{"Statement":{"Effect":"Allow","Principal":{"AWS":"*"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"aws:PrincipalArn":"arn:aws:iam::000000000000:user/nobody"}}}}')" MalformedPolicyDocument
check "and one with a wildcard Deny" "$(code iam create-role --role-name wild --assume-role-policy-document '{"Statement":[{"Effect":"Allow","Principal":{"AWS":"*"},"Action":"sts:AssumeRole"},{"Effect":"Deny","Principal":{"AWS":"*"},"Action":"sts:Assume*"}]}')" MalformedPolicyDocument
aws iam create-role --role-name locked --assume-role-policy-document '{"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::000000000000:user/nobody"},"Action":"sts:AssumeRole"}}' > /dev/null 2>&1
sleep 3
rolecreds=$(aws sts assume-role --role-arn arn:aws:iam::000000000000:role/deployer --role-session-name smoke --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1)
check "an IAM role assumed" "$(echo "$rolecreds" | cut -c1-4)" ASIA
asrole() { ( export AWS_ACCESS_KEY_ID="$(echo "$rolecreds" | cut -f1)" AWS_SECRET_ACCESS_KEY="$(echo "$rolecreds" | cut -f2)" AWS_SESSION_TOKEN="$(echo "$rolecreds" | cut -f3)"; "$@" ); }
check "its session lists what its policy allows" "$(asrole aws s3api list-objects-v2 --bucket smoke --max-keys 1 --query KeyCount --output text 2>&1)" 1
check "and no more" "$(asrole code s3api put-object --bucket smoke --key role.txt --body sse.txt)" AccessDenied
check "a role whose trust names someone else" "$(code sts assume-role --role-arn arn:aws:iam::000000000000:role/locked --role-session-name smoke)" AccessDenied
check "a role with a policy is not deleted" "$(code iam delete-role --role-name deployer)" DeleteConflict
aws iam delete-role-policy --role-name deployer --policy-name list > /dev/null 2>&1
aws iam delete-role --role-name deployer > /dev/null 2>&1 && pass "iam delete-role" || fail "iam delete-role"
# Made again under its name: the old role's session is refused, a new one's is taken (ADR-0106 §1.5).
aws iam create-role --role-name deployer --assume-role-policy-document "$trustroot" > /dev/null 2>&1
aws iam put-role-policy --role-name deployer --policy-name list --policy-document '{"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::smoke"}}' > /dev/null 2>&1
sleep 3
check "a session of the role deleted, refused once it is made again" "$(asrole code s3api list-objects-v2 --bucket smoke --max-keys 1)" InvalidToken
rolecreds=$(aws sts assume-role --role-arn arn:aws:iam::000000000000:role/deployer --role-session-name again --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1)
check "while the new role's session lists" "$(asrole aws s3api list-objects-v2 --bucket smoke --max-keys 1 --query KeyCount --output text 2>&1)" 1
aws iam delete-role-policy --role-name deployer --policy-name list > /dev/null 2>&1
aws iam delete-role --role-name deployer > /dev/null 2>&1
aws iam delete-role --role-name locked > /dev/null 2>&1
check "the API's roles gone, the file's listed" "$(aws iam list-roles --query 'Roles[].RoleName' --output text 2>&1)" reader
# Managed policies (ADR-0108 §3): made, versioned and attached; a user may do what their default versions allow.
pol1='{"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::smoke"}}'
pol2='{"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["s3:ListBucket","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::smoke","arn:aws:s3:::smoke/mp.txt"]}}'
parn=arn:aws:iam::000000000000:policy/team/smoke-list
check "iam create-policy" "$(aws iam create-policy --policy-name smoke-list --path /team/ --policy-document "$pol1" --tags Key=team,Value=data --query 'Policy.[Arn,DefaultVersionId]' --output text 2>&1 | tr '\t' ' ')" "$parn v1"
check "a policy's name twice" "$(code iam create-policy --policy-name smoke-list --policy-document "$pol1")" EntityAlreadyExists
check "nor a path IAM does not take" "$(code iam create-policy --policy-name p2 --path team --policy-document "$pol1")" ValidationError
check "iam get-policy" "$(aws iam get-policy --policy-arn $parn --query 'Policy.[PolicyName,Path,AttachmentCount,Tags[0].Value]' --output text 2>&1 | tr '\t' ' ')" "smoke-list /team/ 0 data"
aws iam create-user --user-name mp > /dev/null 2>&1
mpkey=$(aws iam create-access-key --user-name mp --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text 2>&1)
mpid=$(echo "$mpkey" | cut -f1); mpsecret=$(echo "$mpkey" | cut -f2)
mp() { ( export AWS_ACCESS_KEY_ID="$mpid" AWS_SECRET_ACCESS_KEY="$mpsecret"; "$@" ); }
aws iam attach-user-policy --user-name mp --policy-arn $parn > /dev/null 2>&1 && pass "iam attach-user-policy" || fail "iam attach-user-policy"
check "listed attached" "$(aws iam list-attached-user-policies --user-name mp --query 'AttachedPolicies[].PolicyName' --output text 2>&1)" smoke-list
check "a policy not there not attached" "$(code iam attach-user-policy --user-name mp --policy-arn arn:aws:iam::000000000000:policy/none)" NoSuchEntity
sleep 3
check "its default version allows" "$(mp aws s3api list-objects-v2 --bucket smoke --max-keys 1 --query KeyCount --output text 2>&1)" 1
check "and no more" "$(mp code s3api put-object --bucket smoke --key mp.txt --body sse.txt)" AccessDenied
check "iam create-policy-version" "$(aws iam create-policy-version --policy-arn $parn --policy-document "$pol2" --query 'PolicyVersion.[VersionId,IsDefaultVersion]' --output text 2>&1 | tr '\t' ' ')" "v2 False"
sleep 3
check "a version not the default allows nothing more" "$(mp code s3api put-object --bucket smoke --key mp.txt --body sse.txt)" AccessDenied
aws iam set-default-policy-version --policy-arn $parn --version-id v2 > /dev/null 2>&1 && pass "iam set-default-policy-version" || fail "iam set-default-policy-version"
check "its document read back" "$(aws iam get-policy-version --policy-arn $parn --version-id v2 --query 'PolicyVersion.[IsDefaultVersion,Document.Statement.Action[1]]' --output text 2>&1 | tr '\t' ' ')" "True s3:PutObject"
check "the versions listed" "$(aws iam list-policy-versions --policy-arn $parn --query 'Versions[].VersionId' --output text 2>&1 | tr '\t' ' ')" "v1 v2"
sleep 3
check "the new default allows" "$(mp aws s3api put-object --bucket smoke --key mp.txt --body sse.txt > /dev/null 2>&1 && echo yes)" yes
check "the default version not deleted" "$(code iam delete-policy-version --policy-arn $parn --version-id v2)" DeleteConflict
check "nor an attached policy" "$(code iam delete-policy --policy-arn $parn)" DeleteConflict
check "its users listed" "$(aws iam list-entities-for-policy --policy-arn $parn --query 'PolicyUsers[].UserName' --output text 2>&1)" mp
check "AWS's read-only S3 policy" "$(aws iam get-policy-version --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess --version-id v1 --query 'PolicyVersion.Document.Statement[0].Action[0]' --output text 2>&1)" 's3:Get*'
aws iam attach-user-policy --user-name mp --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess > /dev/null 2>&1
check "listed among AWS's, attached" "$(aws iam list-policies --scope AWS --only-attached --query 'Policies[].PolicyName' --output text 2>&1)" AmazonS3ReadOnlyAccess
check "and the account's" "$(aws iam list-policies --scope Local --query 'Policies[].[PolicyName,AttachmentCount]' --output text 2>&1 | tr '\t' ' ')" "smoke-list 1"
mp aws s3api delete-object --bucket smoke --key mp.txt > /dev/null 2>&1
aws iam delete-access-key --user-name mp --access-key-id "$mpid" > /dev/null 2>&1
check "a user with policies attached not deleted" "$(code iam delete-user --user-name mp)" DeleteConflict
aws iam detach-user-policy --user-name mp --policy-arn $parn > /dev/null 2>&1 && pass "iam detach-user-policy" || fail "iam detach-user-policy"
aws iam detach-user-policy --user-name mp --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess > /dev/null 2>&1
aws iam delete-user --user-name mp > /dev/null 2>&1 && pass "then deleted" || fail "then deleted"
aws iam delete-policy-version --policy-arn $parn --version-id v1 > /dev/null 2>&1 && pass "iam delete-policy-version" || fail "iam delete-policy-version"
aws iam delete-policy --policy-arn $parn > /dev/null 2>&1 && pass "iam delete-policy" || fail "iam delete-policy"
check "gone" "$(code iam get-policy --policy-arn $parn)" NoSuchEntity
# Groups (ADR-0108 §3): a member may do what its groups' inline and attached policies allow.
group=$(aws iam create-group --group-name smoke-editors --path /team/ --query 'Group.[Arn,GroupId]' --output text 2>&1)
check "iam create-group" "$(echo "$group" | cut -f1) $(echo "$group" | cut -f2 | cut -c1-4)" "arn:aws:iam::000000000000:group/team/smoke-editors AGPA"
check "a group's name twice" "$(code iam create-group --group-name smoke-editors)" EntityAlreadyExists
aws iam create-user --user-name gm > /dev/null 2>&1
gmkey=$(aws iam create-access-key --user-name gm --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text 2>&1)
gmid=$(echo "$gmkey" | cut -f1); gmsecret=$(echo "$gmkey" | cut -f2)
gm() { ( export AWS_ACCESS_KEY_ID="$gmid" AWS_SECRET_ACCESS_KEY="$gmsecret"; "$@" ); }
aws iam add-user-to-group --group-name smoke-editors --user-name gm > /dev/null 2>&1 && pass "iam add-user-to-group" || fail "iam add-user-to-group"
check "a user not the API's is in no group" "$(code iam add-user-to-group --group-name smoke-editors --user-name nobody)" NoSuchEntity
check "its members got" "$(aws iam get-group --group-name smoke-editors --query 'Users[].UserName' --output text 2>&1)" gm
check "the user's groups listed" "$(aws iam list-groups-for-user --user-name gm --query 'Groups[].GroupName' --output text 2>&1)" smoke-editors
check "listed by path" "$(aws iam list-groups --path-prefix /team/ --query 'Groups[].GroupName' --output text 2>&1)" smoke-editors
aws iam put-group-policy --group-name smoke-editors --policy-name list --policy-document "$pol1" > /dev/null 2>&1 && pass "iam put-group-policy" || fail "iam put-group-policy"
check "its policy read back" "$(aws iam get-group-policy --group-name smoke-editors --policy-name list --query 'PolicyDocument.Statement.Action' --output text 2>&1)" s3:ListBucket
check "its policies listed" "$(aws iam list-group-policies --group-name smoke-editors --query PolicyNames --output text 2>&1)" list
aws iam attach-group-policy --group-name smoke-editors --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess > /dev/null 2>&1 && pass "iam attach-group-policy" || fail "iam attach-group-policy"
check "its attached policies listed" "$(aws iam list-attached-group-policies --group-name smoke-editors --query 'AttachedPolicies[].PolicyName' --output text 2>&1)" AmazonS3FullAccess
sleep 3
check "a member lists by its group's inline policy" "$(gm aws s3api list-objects-v2 --bucket smoke --max-keys 1 --query KeyCount --output text 2>&1)" 1
check "and writes by its attached one" "$(gm aws s3api put-object --bucket smoke --key gm.txt --body sse.txt > /dev/null 2>&1 && echo yes)" yes
gm aws s3api delete-object --bucket smoke --key gm.txt > /dev/null 2>&1
aws iam detach-group-policy --group-name smoke-editors --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess > /dev/null 2>&1 && pass "iam detach-group-policy" || fail "iam detach-group-policy"
sleep 3
check "detached, it writes no more" "$(gm code s3api put-object --bucket smoke --key gm.txt --body sse.txt)" AccessDenied
check "a group with members not deleted" "$(code iam delete-group --group-name smoke-editors)" DeleteConflict
aws iam delete-access-key --user-name gm --access-key-id "$gmid" > /dev/null 2>&1
check "nor a user in a group" "$(code iam delete-user --user-name gm)" DeleteConflict
aws iam remove-user-from-group --group-name smoke-editors --user-name gm > /dev/null 2>&1 && pass "iam remove-user-from-group" || fail "iam remove-user-from-group"
aws iam delete-user --user-name gm > /dev/null 2>&1
check "nor a group with a policy" "$(code iam delete-group --group-name smoke-editors)" DeleteConflict
aws iam delete-group-policy --group-name smoke-editors --policy-name list > /dev/null 2>&1 && pass "iam delete-group-policy" || fail "iam delete-group-policy"
aws iam delete-group --group-name smoke-editors > /dev/null 2>&1 && pass "iam delete-group" || fail "iam delete-group"
check "the group gone" "$(code iam get-group --group-name smoke-editors)" NoSuchEntity
# Tags, paths, role updates, the refresh's reads, and GetCallerIdentity (ADR-0108 §3).
check "a user made with a path and tags" "$(aws iam create-user --user-name tg --path /staff/ --tags Key=team,Value=data --query 'User.[Arn,Tags[0].Value]' --output text 2>&1 | tr '\t' ' ')" "arn:aws:iam::000000000000:user/staff/tg data"
aws iam tag-user --user-name tg --tags Key=cost,Value=7 Key=team,Value=ops > /dev/null 2>&1 && pass "iam tag-user" || fail "iam tag-user"
check "its tags listed, merged by key" "$(aws iam list-user-tags --user-name tg --query 'Tags[].[Key,Value]' --output text 2>&1 | tr '\t\n' '= ' | sed 's/ $//')" "team=ops cost=7"
aws iam untag-user --user-name tg --tag-keys cost > /dev/null 2>&1 && pass "iam untag-user" || fail "iam untag-user"
check "and in GetUser" "$(aws iam get-user --user-name tg --query 'User.[Path,Tags[].Key]' --output text 2>&1 | tr '\t\n' '  ' | sed 's/ *$//')" "/staff/ team"
tgkey=$(aws iam create-access-key --user-name tg --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text 2>&1)
tgid=$(echo "$tgkey" | cut -f1); tgsecret=$(echo "$tgkey" | cut -f2)
tg() { ( export AWS_ACCESS_KEY_ID="$tgid" AWS_SECRET_ACCESS_KEY="$tgsecret"; "$@" ); }
check "a key never used" "$(aws iam get-access-key-last-used --access-key-id "$tgid" --query '[UserName,AccessKeyLastUsed.ServiceName]' --output text 2>&1 | tr '\t' ' ')" "tg N/A"
check "no login profile" "$(code iam get-login-profile --user-name tg)" NoSuchEntity
check "no MFA devices" "$(aws iam list-mfa-devices --user-name tg --query 'length(MFADevices)' --output text 2>&1)" 0
check "no SSH keys" "$(aws iam list-ssh-public-keys --user-name tg --query 'length(SSHPublicKeys)' --output text 2>&1)" 0
check "no signing certificates" "$(aws iam list-signing-certificates --user-name tg --query 'length(Certificates)' --output text 2>&1)" 0
check "no service credentials" "$(aws iam list-service-specific-credentials --user-name tg --query 'length(ServiceSpecificCredentials)' --output text 2>&1)" 0
# A policy naming the user by its ARN, path and all, allows; by the ARN without its path, nothing.
aws iam put-user-policy --user-name tg --policy-name self --policy-document '{"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"iam:ListUserTags","Resource":"arn:aws:iam::000000000000:user/staff/tg"}}' > /dev/null 2>&1
sleep 3
check "a policy on its ARN with its path" "$(tg aws iam list-user-tags --user-name tg --query 'Tags[0].Key' --output text 2>&1)" team
aws iam put-user-policy --user-name tg --policy-name self --policy-document '{"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"iam:ListUserTags","Resource":"arn:aws:iam::000000000000:user/tg"}}' > /dev/null 2>&1
sleep 3
check "and not without it" "$(tg code iam list-user-tags --user-name tg)" AccessDenied
check "GetCallerIdentity, the account's" "$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>&1 | tr '\t' ' ')" "000000000000 arn:aws:iam::000000000000:root"
tgwho=$(tg aws sts get-caller-identity --query '[Arn,UserId]' --output text 2>&1)
check "a user's, with its path" "$(echo "$tgwho" | cut -f1) $(echo "$tgwho" | cut -f2 | cut -c1-4)" "arn:aws:iam::000000000000:user/staff/tg AIDA"
check "a role made with a path and a description" "$(aws iam create-role --role-name tr --path /svc/ --description first --assume-role-policy-document '{"Statement":{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::000000000000:user/nobody"},"Action":"sts:AssumeRole"}}' --tags Key=env,Value=test --query 'Role.[Arn,Description]' --output text 2>&1 | tr '\t' ' ')" "arn:aws:iam::000000000000:role/svc/tr first"
aws iam update-role --role-name tr --description second --max-session-duration 7200 > /dev/null 2>&1 && pass "iam update-role" || fail "iam update-role"
check "its description and sessions changed" "$(aws iam get-role --role-name tr --query 'Role.[Description,MaxSessionDuration,Tags[0].Value]' --output text 2>&1 | tr '\t' ' ')" "second 7200 test"
aws iam tag-role --role-name tr --tags Key=owner,Value=ops > /dev/null 2>&1 && pass "iam tag-role" || fail "iam tag-role"
check "its tags listed" "$(aws iam list-role-tags --role-name tr --query 'Tags[].Key' --output text 2>&1 | tr '\t' ' ')" "env owner"
aws iam untag-role --role-name tr --tag-keys owner > /dev/null 2>&1
check "its trust refuses the account" "$(code sts assume-role --role-arn arn:aws:iam::000000000000:role/svc/tr --role-session-name ss)" AccessDenied
aws iam update-assume-role-policy --role-name tr --policy-document "$trustroot" > /dev/null 2>&1 && pass "iam update-assume-role-policy" || fail "iam update-assume-role-policy"
aws iam put-role-policy --role-name tr --policy-name list --policy-document "$pol1" > /dev/null 2>&1
check "its inline policies listed" "$(aws iam list-role-policies --role-name tr --query PolicyNames --output text 2>&1)" list
check "no instance profiles" "$(aws iam list-instance-profiles-for-role --role-name tr --query 'length(InstanceProfiles)' --output text 2>&1)" 0
sleep 3
trcreds=$(aws sts assume-role --role-arn arn:aws:iam::000000000000:role/svc/tr --role-session-name smoke --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1)
check "the new trust lets the account assume it" "$(echo "$trcreds" | cut -c1-4)" ASIA
check "GetCallerIdentity, a session's" "$( ( export AWS_ACCESS_KEY_ID="$(echo "$trcreds" | cut -f1)" AWS_SECRET_ACCESS_KEY="$(echo "$trcreds" | cut -f2)" AWS_SESSION_TOKEN="$(echo "$trcreds" | cut -f3)"; aws sts get-caller-identity --query Arn --output text 2>&1 ) )" "arn:aws:sts::000000000000:assumed-role/tr/smoke"
# The M21 exit review's findings 2, 3 and 5: AssumeRole takes the role's own path only and is decided on its ARN with
# it; a trust policy names a user with its path; CreateUser is decided at the Path given.
check "a RoleArn with another path refused" "$(code sts assume-role --role-arn arn:aws:iam::000000000000:role/other/tr --role-session-name ss)" AccessDenied
aws iam update-assume-role-policy --role-name tr --policy-document '{"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::000000000000:user/staff/tg"},"Action":"sts:AssumeRole"}}' > /dev/null 2>&1
aws iam put-user-policy --user-name tg --policy-name assume --policy-document '{"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"sts:AssumeRole","Resource":"arn:aws:iam::000000000000:role/svc/tr"}}' > /dev/null 2>&1
sleep 3
check "a user its trust names with its path, allowed the role's ARN with its path, assumes it" "$(tg aws sts assume-role --role-arn arn:aws:iam::000000000000:role/svc/tr --role-session-name tg --query 'Credentials.AccessKeyId' --output text 2>&1 | cut -c1-4)" ASIA
aws iam put-user-policy --user-name tg --policy-name assume --policy-document '{"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"sts:AssumeRole","Resource":"arn:aws:iam::000000000000:role/tr"}}' > /dev/null 2>&1
sleep 3
check "but not allowed it on its ARN without the path" "$(tg code sts assume-role --role-arn arn:aws:iam::000000000000:role/svc/tr --role-session-name tg)" AccessDenied
aws iam put-user-policy --user-name tg --policy-name assume --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"iam:CreateUser","Resource":"*"},{"Effect":"Deny","Action":"iam:CreateUser","Resource":"arn:aws:iam::000000000000:user/admin/*"}]}' > /dev/null 2>&1
sleep 3
check "a user denied user/admin/* does not make one there" "$(tg code iam create-user --user-name boss --path /admin/)" AccessDenied
check "but may elsewhere" "$(tg aws iam create-user --user-name notboss --path /ok/ --query User.Path --output text 2>&1)" /ok/
aws iam delete-user --user-name notboss > /dev/null 2>&1
aws iam delete-user-policy --user-name tg --policy-name assume > /dev/null 2>&1
aws iam create-policy --policy-name tagged --policy-document "$pol1" > /dev/null 2>&1
aws iam tag-policy --policy-arn arn:aws:iam::000000000000:policy/tagged --tags Key=a,Value=b > /dev/null 2>&1 && pass "iam tag-policy" || fail "iam tag-policy"
check "its tags listed" "$(aws iam list-policy-tags --policy-arn arn:aws:iam::000000000000:policy/tagged --query 'Tags[0].Value' --output text 2>&1)" b
check "AWS's policies not tagged" "$(code iam tag-policy --policy-arn arn:aws:iam::aws:policy/AdministratorAccess --tags Key=a,Value=b)" NoSuchEntity
aws iam delete-policy --policy-arn arn:aws:iam::000000000000:policy/tagged > /dev/null 2>&1
aws iam delete-role-policy --role-name tr --policy-name list > /dev/null 2>&1
aws iam delete-role --role-name tr > /dev/null 2>&1 && pass "the role deleted" || fail "the role deleted"
aws iam delete-access-key --user-name tg --access-key-id "$tgid" > /dev/null 2>&1
aws iam delete-user-policy --user-name tg --policy-name self > /dev/null 2>&1
aws iam delete-user --user-name tg > /dev/null 2>&1 && pass "the user deleted" || fail "the user deleted"
check "a roles file's role got" "$(aws iam get-role --role-name reader --query 'Role.[Arn,MaxSessionDuration]' --output text 2>&1 | tr '\t' ' ')" "arn:aws:iam::000000000000:role/reader 3600"
check "the account's keys listed" "$(aws iam list-access-keys --query "AccessKeyMetadata[?AccessKeyId=='$AWS_ACCESS_KEY_ID'].Status" --output text 2>&1)" Active
check "another account's role is none" "$(code sts assume-role --role-arn arn:aws:iam::123456789012:role/reader --role-session-name smoke)" AccessDenied
# The records' hidden bucket is no client's (ADR-0104 §3).
check "the IAM bucket refused to S3" "$(code s3api list-objects-v2 --bucket _cosmostore-iam)" InvalidBucketName
check "and never listed" "$(aws s3api list-buckets --query 'Buckets[?starts_with(Name, `_`)].Name' --output text 2>&1)" ""
# Nor a copy's source (the M19 exit review: a copy read the record, every secret in it), nor any destination.
check "nor a copy's source" "$(code s3api copy-object --bucket smoke --key leak --copy-source _cosmostore-iam/state)" InvalidBucketName
check "nor a part copy's" "$(upid=$(aws s3api create-multipart-upload --bucket smoke --key leak --query UploadId --output text); code s3api upload-part-copy --bucket smoke --key leak --upload-id "$upid" --part-number 1 --copy-source /_cosmostore-iam/state; aws s3api abort-multipart-upload --bucket smoke --key leak --upload-id "$upid" > /dev/null 2>&1)" InvalidBucketName
check "nothing copied" "$(code s3api head-object --bucket smoke --key leak)" 404
check "nor a log's target" "$(code s3api put-bucket-logging --bucket smoke --bucket-logging-status '{"LoggingEnabled":{"TargetBucket":"_cosmostore-iam","TargetPrefix":"x/"}}')" InvalidTargetBucketForLogging
check "nor an inventory's destination" "$(code s3api put-bucket-inventory-configuration --bucket smoke --id leak --inventory-configuration '{"Id":"leak","IsEnabled":true,"Destination":{"S3BucketDestination":{"Bucket":"arn:aws:s3:::_cosmostore-iam","Format":"CSV"}},"Schedule":{"Frequency":"Daily"},"IncludedObjectVersions":"Current"}')" InvalidArgument
check "nor an access point's bucket" "$(AWS_ENDPOINT_URL="http://localhost:$port" aws s3control create-access-point --account-id 000000000000 --name leak-ap --bucket _cosmostore-iam 2>&1 | sed -n 's/.*error occurred (\([A-Za-z0-9]*\)).*/\1/p' | head -1)" InvalidBucketName

# Credential rotation (ADR-0050): the credentials file is read again when it changes, within an upkeep round (2 s).
second() { ( export AWS_ACCESS_KEY_ID=AKIASMOKETEST0000002; export AWS_SECRET_ACCESS_KEY="$1"; shift; "$@" ); }
check "a key the file does not have" "$(second second/secret/one code s3api list-buckets)" InvalidAccessKeyId
echo "AKIASMOKETEST0000002 second/secret/one" >> credentials
sleep 4
check "a key added to the file" "$(second second/secret/one aws s3api list-buckets --query 'length(Buckets)')" 1
printf '%s\n' "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" "AKIASMOKETEST0000002 second/secret/two" > credentials
sleep 4
check "its old secret" "$(second second/secret/one code s3api list-buckets)" SignatureDoesNotMatch
check "its new secret" "$(second second/secret/two aws s3api list-buckets --query 'length(Buckets)')" 1
: > credentials
sleep 4
check "a file without keys changes nothing" "$(aws s3api list-buckets --query 'length(Buckets)') $(second second/secret/two aws s3api list-buckets --query 'length(Buckets)')" "1 1"
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > credentials
sleep 4
check "a key taken out of the file" "$(second second/secret/two code s3api list-buckets)" InvalidAccessKeyId
check "the first key through it all" "$(aws s3api list-buckets --query 'length(Buckets)')" 1
# At least the three of this section's file changes: the IAM API's above add their own, as many as rounds took them.
check "the reloads in the log" "$([ "$(grep -c 'credentials reloaded' server.log)" -ge 3 ] && echo some) $(grep -c 'credentials reload failed' server.log)" "some 1"

# Rate limits (ADR-0053): a second server with a limit, so this one's requests are not held back. The limits are
# low and the bounds wide: however slowly the requests go, some are let through and many are slowed.
limitport=$((port + 2))
burst() { n=0; i=0; while [ "$i" -lt "$1" ]; do [ "$(curl -s -o /dev/null -w '%{http_code}' "$2")" = 503 ] && n=$((n + 1)); i=$((i + 1)); done; echo "$n"; }
within() { [ "$1" -ge "$2" ] && [ "$1" -le "$3" ] && echo yes || echo "$1"; }
"$bin" serve "$work/limited" "$limitport" "$work/credentials" --rate-limit-address 3 2> "$work/limited.log" &
limited=$!
sleep 1
check "an address past its limit is slowed" "$(within "$(burst 60 "http://127.0.0.1:$limitport/")" 20 57)" yes
i=0; while [ "$i" -lt 60 ]; do curl -s -o /dev/null -D slow.out "http://127.0.0.1:$limitport/"; grep -q '^HTTP[^ ]* 503' slow.out && break; i=$((i + 1)); done
check "it is told how long to wait" "$(grep -ci '^retry-after: 1' slow.out)" 1
sleep 2
check "a later second is its own" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$limitport/")" 403
kill "$limited"
wait "$limited" 2> /dev/null
"$bin" serve "$work/limited" "$limitport" "$work/credentials" --rate-limit-key 2 2>> "$work/limited.log" &
limited=$!
sleep 1
listurl=$(python3 -I "$here/s3_raw.py" presign "http://127.0.0.1:$limitport" GET "" "" 60)
check "a key past its limit is slowed" "$(within "$(burst 40 "$listurl")" 10 38)" yes
check "an address is not, without that limit" "$(burst 20 "http://127.0.0.1:$limitport/")" 0
kill "$limited"
wait "$limited" 2> /dev/null

# The audit log (ADR-0051): a line of JSON for every request so far, written within a moment of its response.
audit() { python3 -I -c 'import json,sys
lines=[json.loads(l) for l in open("audit.log")]
print(eval(sys.argv[1]))' "$1"; }
sleep 1
check "every line is a request" "$(audit 'all(set(l) >= {"time","id","remote","requester","method","path","query","result","micros"} for l in lines) and len(lines) > 400')" True
check "the key that signed" "$(audit 'len([l for l in lines if l["requester"] == "AKIASMOKETEST0000001" and l["method"] == "PUT" and l["path"] == "/smoke/a/small.txt" and l["result"] == "ok"]) > 0')" True
check "the second key, while it was accepted" "$(audit 'len([l for l in lines if l["requester"] == "AKIASMOKETEST0000002" and l["result"] == "ok"])')" 3
check "anonymous requests, refused and not" "$(audit 'sorted({l["result"] for l in lines if l["requester"] == "anonymous"} & {"ok", "AccessDenied"})')" "['AccessDenied', 'ok']"
check "an error's status" "$(audit 'sorted({l["status"] for l in lines if l["result"] == "AccessDenied"})')" "[403]"
check "a signature that did not check" "$(audit '"-" in {l["requester"] for l in lines if l["result"] == "SignatureDoesNotMatch"}')" True
check "a preflight" "$(audit 'len([l for l in lines if l["method"] == "OPTIONS"]) > 5')" True
check "where the requests came from" "$(audit 'sorted({l["remote"] for l in lines})')" "['127.0.0.1']"
check "a query's names" "$(audit 'len([l for l in lines if l["query"] == "versionId" and l["method"] == "DELETE"]) > 0')" True
check "no value of a presigned URL" "$(grep -c 'X-Amz-Signature=' audit.log) $(audit 'len([l for l in lines if "X-Amz-Signature" in l["query"]]) > 0')" "0 True"
check "no line dropped" "$(stat auditLinesDropped)" 0

# Server access logs (ADR-0072): a bucket's requests delivered as log objects into its target bucket.
aws s3api create-bucket --bucket smokelogs > /dev/null 2>&1
check "logging to a bucket that is not there" "$(code s3api put-bucket-logging --bucket smoke --bucket-logging-status '{"LoggingEnabled":{"TargetBucket":"nologs","TargetPrefix":"x/"}}')" InvalidTargetBucketForLogging
aws s3api put-bucket-logging --bucket smoke --bucket-logging-status '{"LoggingEnabled":{"TargetBucket":"smokelogs","TargetPrefix":"access/"}}' > /dev/null 2>&1 && pass "put-bucket-logging" || fail "put-bucket-logging"
check "get-bucket-logging" "$(aws s3api get-bucket-logging --bucket smoke --query LoggingEnabled.[TargetBucket,TargetPrefix] --output text 2>&1)" "smokelogs	access/"
printf 'logged' > logged.txt
aws s3api put-object --bucket smoke --key logged.txt --body logged.txt > /dev/null 2>&1
code s3api get-object --bucket smoke --key not-here notthere.out > /dev/null
# Both lines, which may come in one log object or in two deliveries 2 s apart.
for i in $(seq 1 40); do
    rm -rf logs.got && mkdir logs.got && aws s3 cp --recursive s3://smokelogs/access/ logs.got/ > /dev/null 2>&1
    [ "$(cat logs.got/* 2>/dev/null | grep -c 'REST.PUT.OBJECT logged.txt\|REST.GET.OBJECT not-here')" -ge 2 ] && break
    sleep 0.25
done
check "the log object is delivered" "$(ls logs.got | wc -l | tr -d ' ' | awk '{ print ($1 >= 1) ? "yes" : "no" }')" yes
check "it has the PUT's line" "$(cat logs.got/* | grep -c '^cosmostore smoke \[.*REST.PUT.OBJECT logged.txt "PUT /smoke/logged.txt HTTP/1.1" 200 ')" 1
check "and the missing key's, with its error" "$(cat logs.got/* | grep -c 'REST.GET.OBJECT not-here .* 404 NoSuchKey ')" 1
# Partitioned keys (ADR-0130 §3), as the CLI sends them (the date source a child element): kept and answered, and its
# logs delivered under `<prefix><account>/<region>/<bucket>/YYYY/MM/DD/`.
aws s3api put-bucket-logging --bucket smoke --bucket-logging-status '{"LoggingEnabled":{"TargetBucket":"smokelogs","TargetPrefix":"parted/","TargetObjectKeyFormat":{"PartitionedPrefix":{"PartitionDateSource":"DeliveryTime"}}}}' > /dev/null 2>&1 && pass "put-bucket-logging with PartitionedPrefix" || fail "put-bucket-logging with PartitionedPrefix"
check "its date source answered" "$(aws s3api get-bucket-logging --bucket smoke --query LoggingEnabled.TargetObjectKeyFormat.PartitionedPrefix.PartitionDateSource --output text 2>&1)" DeliveryTime
aws s3api head-bucket --bucket smoke > /dev/null 2>&1
parted=""
for i in $(seq 1 30); do
    parted=$(aws s3api list-objects-v2 --bucket smokelogs --prefix "parted/000000000000/us-east-1/smoke/$(date -u +%Y/%m/%d)/" --query 'length(Contents || `[]`)' --output text 2>&1)
    [ "$parted" != 0 ] && break
    sleep 0.5
done
check "delivered under a partitioned key" "$([ "$parted" != 0 ] && echo yes)" yes
aws s3api put-bucket-logging --bucket smoke --bucket-logging-status '{}' > /dev/null 2>&1
check "logging off" "$(aws s3api get-bucket-logging --bucket smoke --output text 2>&1)" ""

# STS (ADR-0075): temporary credentials sign S3 requests with their session token.
printf 'from a session' > sts.txt
aws s3api put-object --bucket smoke --key sts/sts.txt --body sts.txt > /dev/null 2>&1
as_session() { AWS_ACCESS_KEY_ID="$1" AWS_SECRET_ACCESS_KEY="$2" AWS_SESSION_TOKEN="$3" "${@:4}"; }
read -r sk ss st <<< "$(aws sts get-session-token --duration-seconds 900 --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1)"
check "get-session-token gives an ASIA key" "${sk:0:4}" ASIA
check "the session reads" "$(as_session "$sk" "$ss" "$st" aws s3 cp s3://smoke/sts/sts.txt - 2>&1)" "$(cat sts.txt)"
as_session "$sk" "$ss" "$st" aws s3api put-object --bucket smoke --key sts/by-session.txt --body sts.txt > /dev/null 2>&1 && pass "the session writes, as its key" || fail "the session writes, as its key"
check "a session token changed" "$(as_session "$sk" "$ss" "${st%????}AAAA" code s3api list-buckets)" InvalidToken
check "the wrong secret for the token" "$(as_session "$sk" "wrong" "$st" code s3api list-buckets)" SignatureDoesNotMatch
check "a session makes no sessions" "$(as_session "$sk" "$ss" "$st" code sts get-session-token)" AccessDenied
check "a session is no admin" "$(as_session "$sk" "$ss" "$st" code s3api get-object --bucket _cosmostore --key stats /dev/null)" AccessDenied
check "out of range" "$(code sts get-session-token --duration-seconds 200000)" ValidationError
read -r rk rs rt <<< "$(aws sts assume-role --role-arn arn:aws:iam::000000000000:role/reader --role-session-name smoke --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1)"
check "assume-role gives an ASIA key" "${rk:0:4}" ASIA
check "the role reads" "$(as_session "$rk" "$rs" "$rt" aws s3 cp s3://smoke/sts/sts.txt - 2>&1)" "$(cat sts.txt)"
check "the role lists" "$(as_session "$rk" "$rs" "$rt" aws s3api list-objects-v2 --bucket smoke --prefix sts/ --query 'length(Contents)' --output text 2>&1)" 2
check "the role does not write" "$(as_session "$rk" "$rs" "$rt" code s3api put-object --bucket smoke --key sts/no --body sts.txt)" AccessDenied
check "the role does not delete" "$(as_session "$rk" "$rs" "$rt" code s3api delete-object --bucket smoke --key sts/sts.txt)" AccessDenied
check "nor delete in a batch" "$(as_session "$rk" "$rs" "$rt" aws s3api delete-objects --bucket smoke --delete '{"Objects":[{"Key":"sts/sts.txt"}]}' --query 'Errors[0].Code' --output text 2>&1)" AccessDenied
check "nor list the buckets" "$(as_session "$rk" "$rs" "$rt" code s3api list-buckets)" AccessDenied
check "nor make one" "$(as_session "$rk" "$rs" "$rt" code s3api create-bucket --bucket sts-made)" AccessDenied
check "nor read another bucket" "$(as_session "$rk" "$rs" "$rt" code s3api list-objects-v2 --bucket smokelogs)" AccessDenied
check "nor copy out of it" "$(as_session "$rk" "$rs" "$rt" code s3api copy-object --bucket smoke --key sts/copy --copy-source smoke/sts/sts.txt)" AccessDenied
url=$(as_session "$rk" "$rs" "$rt" aws s3 presign s3://smoke/sts/sts.txt --expires-in 300 2>&1)
check "a presigned URL of the role" "$(curl -s "$url")" "$(cat sts.txt)"
check "a role that is not there" "$(code sts assume-role --role-arn arn:aws:iam::000000000000:role/nobody --role-session-name smoke)" AccessDenied
check "longer than the role allows" "$(code sts assume-role --role-arn arn:aws:iam::000000000000:role/reader --role-session-name smoke --duration-seconds 7200)" ValidationError
read -r pk ps pt <<< "$(aws sts assume-role --role-arn arn:aws:iam::000000000000:role/reader --role-session-name narrow --policy '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::smoke/*"}]}' --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1)"
check "a session policy narrows the role: it reads" "$(as_session "$pk" "$ps" "$pt" aws s3 cp s3://smoke/sts/sts.txt - 2>&1)" "$(cat sts.txt)"
check "but does not list" "$(as_session "$pk" "$ps" "$pt" code s3api list-objects-v2 --bucket smoke)" AccessDenied
check "a client's replica fields are refused (M7 review B2)" "$(python3 -I "$here/s3_raw.py" put-with "$AWS_ENDPOINT_URL" smoke forged.txt forged x-cosmo-replica-version:0123456789abcdef0123456789abcdef x-cosmo-replica-md5:0123456789abcdef0123456789abcdef | cut -d' ' -f1)" 403
check "policy ARNs are not done, not dropped" "$(code sts assume-role --role-arn arn:aws:iam::000000000000:role/reader --role-session-name arns --policy-arns arn=arn:aws:iam::aws:policy/ReadOnlyAccess)" NotImplemented
check "a session policy with a principal" "$(code sts assume-role --role-arn arn:aws:iam::000000000000:role/reader --role-session-name bad --policy '{"Statement":{"Effect":"Allow","Principal":"*","Action":"*","Resource":"*"}}')" MalformedPolicyDocument
aws s3 rm --recursive s3://smoke/sts/ > /dev/null 2>&1

# Access Points (ADR-0076): the S3 Control calls through the CLI, then requests by alias and by ARN.
ctl() { AWS_ENDPOINT_URL="http://localhost:$port" aws s3control "$@" --account-id 000000000000; }
apl() { AWS_ENDPOINT_URL="http://localhost:$port" aws "$@"; }
apcode() { AWS_ENDPOINT_URL="http://localhost:$port" aws "$@" 2>&1 | sed -n 's/.*error occurred (\([A-Za-z0-9]*\)).*/\1/p' | head -1; }
printf 'through a door' > ap.txt
alias=$(ctl create-access-point --name smoke-ap --bucket smoke --query Alias --output text 2>&1)
check "create-access-point gives an alias" "${alias: -8}" "-s3alias"
check "get-access-point" "$(ctl get-access-point --name smoke-ap --query '[Bucket,NetworkOrigin,PublicAccessBlockConfiguration.RestrictPublicBuckets]' --output text 2>&1)" "smoke	Internet	True"
check "list-access-points" "$(ctl list-access-points --bucket smoke --query 'AccessPointList[0].Alias' --output text 2>&1)" "$alias"
check "a name twice" "$(apcode s3control create-access-point --account-id 000000000000 --name smoke-ap --bucket smoke)" AccessPointAlreadyOwnedByYou
check "a bucket that is not there" "$(apcode s3control create-access-point --account-id 000000000000 --name nowhere --bucket nobucket)" NoSuchBucket
aws s3api put-object --bucket "$alias" --key ap/door.txt --body ap.txt > /dev/null 2>&1 && pass "a write by its alias" || fail "a write by its alias"
check "lands in its bucket" "$(aws s3 cp s3://smoke/ap/door.txt - 2>&1)" "through a door"
check "a read by its alias" "$(aws s3 cp "s3://$alias/ap/door.txt" - 2>&1)" "through a door"
check "a listing by its alias" "$(aws s3api list-objects-v2 --bucket "$alias" --prefix ap/ --query 'Contents[0].Key' --output text 2>&1)" ap/door.txt
check "a read by its ARN" "$(apl s3api get-object --bucket arn:aws:s3:us-east-1:000000000000:accesspoint/smoke-ap --key ap/door.txt ap.out > /dev/null 2>&1; cat ap.out)" "through a door"
check "no bucket configuration through it" "$(code s3api get-bucket-policy --bucket "$alias")" InvalidRequest
check "no anonymous reads through it" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/$alias/ap/door.txt")" 403
ctl put-access-point-policy --name smoke-ap --policy '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":{"AWS":"arn:aws:iam:::user/'"$AWS_ACCESS_KEY_ID"'"},"Action":"s3:PutObject","Resource":"arn:aws:s3:us-east-1:000000000000:accesspoint/smoke-ap/object/*"}]}' > /dev/null 2>&1 && pass "put-access-point-policy" || fail "put-access-point-policy"
check "get-access-point-policy" "$(ctl get-access-point-policy --name smoke-ap --query Policy --output text 2>&1 | grep -c '"Deny"')" 1
check "its policy denies a write through it" "$(code s3api put-object --bucket "$alias" --key ap/no.txt --body ap.txt)" AccessDenied
aws s3api put-object --bucket smoke --key ap/direct.txt --body ap.txt > /dev/null 2>&1 && pass "but not to the bucket itself" || fail "but not to the bucket itself"
check "a public policy under its block" "$(apcode s3control put-access-point-policy --account-id 000000000000 --name smoke-ap --policy '{"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:us-east-1:000000000000:accesspoint/smoke-ap/object/*"}}')" AccessDenied
ctl delete-access-point-policy --name smoke-ap > /dev/null 2>&1
check "the policy deleted" "$(apcode s3control get-access-point-policy --account-id 000000000000 --name smoke-ap)" NoSuchAccessPointPolicy
ctl delete-access-point --name smoke-ap > /dev/null 2>&1
check "the access point deleted" "$(apcode s3control get-access-point --account-id 000000000000 --name smoke-ap)" NoSuchAccessPoint
check "and its alias with it" "$(code s3api list-objects-v2 --bucket "$alias")" NoSuchBucket
aws s3 rm --recursive s3://smoke/ap/ > /dev/null 2>&1

# Replication (ADR-0077): new versions of rsrc go to rdst with their version ids and ETags.
for b in rsrc rdst rplain; do aws s3api create-bucket --bucket $b > /dev/null 2>&1; done
for b in rsrc rdst; do aws s3api put-bucket-versioning --bucket $b --versioning-configuration Status=Enabled > /dev/null 2>&1; done
rconf='{"Role":"arn:aws:iam::000000000000:role/r","Rules":[{"ID":"all","Priority":1,"Status":"Enabled","Filter":{"Prefix":""},"DeleteMarkerReplication":{"Status":"Enabled"},"Destination":{"Bucket":"arn:aws:s3:::rdst","StorageClass":"STANDARD_IA"}}]}'
check "a destination without versioning" "$(code s3api put-bucket-replication --bucket rsrc --replication-configuration "${rconf/rdst/rplain}")" InvalidRequest
aws s3api put-bucket-replication --bucket rsrc --replication-configuration "$rconf" > /dev/null 2>&1 && pass "put-bucket-replication" || fail "put-bucket-replication"
check "get-bucket-replication" "$(aws s3api get-bucket-replication --bucket rsrc --query 'ReplicationConfiguration.Rules[0].Destination.Bucket' --output text 2>&1)" "arn:aws:s3:::rdst"
check "a source keeps its versioning" "$(code s3api put-bucket-versioning --bucket rsrc --versioning-configuration Status=Suspended)" InvalidBucketState
printf 'replicate me' > r1.txt
head -c 9437184 /dev/urandom > r2.bin
aws s3api put-object --bucket rsrc --key r/small.txt --body r1.txt > /dev/null 2>&1
aws s3 cp r2.bin s3://rsrc/r/multi.bin > /dev/null 2>&1
aws s3api put-object --bucket rsrc --key r/sealed.txt --body r1.txt --server-side-encryption AES256 > /dev/null 2>&1
replicated() {
    for i in $(seq 1 80); do
        [ "$(aws s3api head-object --bucket rsrc --key "$1" --query ReplicationStatus --output text 2>/dev/null)" = COMPLETED ] && return 0
        sleep 0.25
    done
    return 1
}
for k in r/small.txt r/multi.bin r/sealed.txt; do
    replicated "$k" && pass "$k replicated" || fail "$k replicated"
    sv=$(aws s3api head-object --bucket rsrc --key "$k" --query '[VersionId,ETag]' --output text 2>&1)
    dv=$(aws s3api head-object --bucket rdst --key "$k" --query '[VersionId,ETag]' --output text 2>&1)
    check "$k keeps its version id and ETag" "$dv" "$sv"
    check "$k is a replica" "$(aws s3api head-object --bucket rdst --key "$k" --query ReplicationStatus --output text 2>&1)" REPLICA
done
check "a multipart ETag" "$(aws s3api head-object --bucket rdst --key r/multi.bin --query ETag --output text 2>&1 | grep -c -- '-2"')" 1
check "replicas get the rule's storage class (M12 review B3)" "$(aws s3api head-object --bucket rdst --key r/multi.bin --query StorageClass --output text 2>&1)" STANDARD_IA
check "and the rule returns it" "$(aws s3api get-bucket-replication --bucket rsrc --query 'ReplicationConfiguration.Rules[0].Destination.StorageClass' --output text 2>&1)" STANDARD_IA
check "the multipart replica's bytes" "$(aws s3 cp s3://rdst/r/multi.bin - 2>/dev/null | cmp -s - r2.bin && echo same)" same
check "the sealed replica reads" "$(aws s3 cp s3://rdst/r/sealed.txt - 2>&1)" "replicate me"
check "and is sealed" "$(aws s3api head-object --bucket rdst --key r/sealed.txt --query ServerSideEncryption --output text 2>&1)" AES256
marker=$(aws s3api delete-object --bucket rsrc --key r/small.txt --query VersionId --output text 2>&1)
for i in $(seq 1 40); do
    got=$(aws s3api list-object-versions --bucket rdst --prefix r/small.txt --query 'DeleteMarkers[0].VersionId' --output text 2>/dev/null)
    [ "$got" = "$marker" ] && break
    sleep 0.25
done
check "a delete marker replicated with its id" "$got" "$marker"
aws s3api put-bucket-replication --bucket rdst --replication-configuration "${rconf//rdst/rsrc}" > /dev/null 2>&1
aws s3api put-object --bucket rsrc --key r/once.txt --body r1.txt > /dev/null 2>&1
replicated r/once.txt && pass "both ways: replicated" || fail "both ways: replicated"
sleep 1
check "a replica is not replicated back" "$(aws s3api list-object-versions --bucket rsrc --prefix r/once.txt --query 'length(Versions)' --output text 2>&1)" 1
aws s3api delete-bucket-replication --bucket rdst > /dev/null 2>&1
aws s3api delete-bucket-replication --bucket rsrc > /dev/null 2>&1
check "delete-bucket-replication" "$(code s3api get-bucket-replication --bucket rsrc)" ReplicationConfigurationNotFoundError
# To the second server: plaintext and ETags, as a PUT or a multipart upload with the source's parts.
printf 'far1 %s\n' "$(head -c 32 /dev/urandom | base64)" > "$work/far.keys"
"$bin" serve "$work/far" "$remoteport" "$work/far.credentials" --sse-key-file "$work/far.keys" 2>> "$work/far.log" &
remote=$!
sleep 1
far() { AWS_ACCESS_KEY_ID=AKIAFARSERVER0000001 AWS_SECRET_ACCESS_KEY=far/secret/0123456789abcdefghij AWS_ENDPOINT_URL="http://127.0.0.1:$remoteport" aws "$@"; }
far s3api create-bucket --bucket faraway > /dev/null 2>&1
far s3api put-bucket-versioning --bucket faraway --versioning-configuration Status=Enabled > /dev/null 2>&1
check "an unknown target" "$(code s3api put-bucket-replication --bucket rsrc --replication-configuration '{"Role":"r","Rules":[{"ID":"far","Priority":1,"Status":"Enabled","Filter":{"Prefix":""},"DeleteMarkerReplication":{"Status":"Enabled"},"Destination":{"Bucket":"arn:cosmostore:s3::nobody:faraway"}}]}')" InvalidArgument
aws s3api put-bucket-replication --bucket rsrc --replication-configuration '{"Role":"r","Rules":[{"ID":"far","Priority":1,"Status":"Enabled","Filter":{"Prefix":"f/"},"DeleteMarkerReplication":{"Status":"Enabled"},"Destination":{"Bucket":"arn:cosmostore:s3::far:faraway"}},{"ID":"lost","Priority":2,"Status":"Enabled","Filter":{"Prefix":"lost/"},"DeleteMarkerReplication":{"Status":"Disabled"},"Destination":{"Bucket":"arn:cosmostore:s3::far:nobucket"}}]}' > /dev/null 2>&1 && pass "put-bucket-replication to another endpoint" || fail "put-bucket-replication to another endpoint"
aws s3api put-object --bucket rsrc --key f/small.txt --body r1.txt --metadata colour=blue > /dev/null 2>&1
aws s3 cp r2.bin s3://rsrc/f/multi.bin > /dev/null 2>&1
aws s3api put-object --bucket rsrc --key f/sealed.txt --body r1.txt --server-side-encryption aws:kms > /dev/null 2>&1
for k in f/small.txt f/multi.bin f/sealed.txt; do
    replicated "$k" && pass "$k replicated far" || fail "$k replicated far"
    # SSE-KMS's ETag is not its plaintext's MD5, which the copy sealed there by SSE-S3 has (ADR-0077 §6).
    [ "$k" != f/sealed.txt ] && check "$k's ETag there" "$(far s3api head-object --bucket faraway --key "$k" --query ETag --output text 2>&1)" "$(aws s3api head-object --bucket rsrc --key "$k" --query ETag --output text 2>&1)"
    check "$k is a replica there" "$(far s3api head-object --bucket faraway --key "$k" --query ReplicationStatus --output text 2>&1)" REPLICA
done
check "its metadata there" "$(far s3api head-object --bucket faraway --key f/small.txt --query Metadata.colour --output text 2>&1)" blue
check "the multipart replica's bytes there" "$(far s3 cp s3://faraway/f/multi.bin - 2>/dev/null | cmp -s - r2.bin && echo same)" same
check "the sealed one's plaintext there" "$(far s3 cp s3://faraway/f/sealed.txt - 2>&1)" "replicate me"
check "sealed there by its own keys" "$(far s3api head-object --bucket faraway --key f/sealed.txt --query ServerSideEncryption --output text 2>&1)" AES256
aws s3api delete-object --bucket rsrc --key f/small.txt > /dev/null 2>&1
for i in $(seq 1 40); do
    got=$(far s3api list-object-versions --bucket faraway --prefix f/small.txt --query 'length(DeleteMarkers)' --output text 2>/dev/null)
    [ "$got" = 1 ] && break
    sleep 0.25
done
check "a delete marker there" "$got" 1
aws s3api put-object --bucket rsrc --key lost/x.txt --body r1.txt > /dev/null 2>&1
for i in $(seq 1 40); do
    st=$(aws s3api head-object --bucket rsrc --key lost/x.txt --query ReplicationStatus --output text 2>/dev/null)
    [ "$st" = FAILED ] && break
    sleep 0.25
done
check "a destination that refuses: FAILED" "$st" FAILED
kill "$server"; wait "$server" 2>/dev/null; start_server
check "FAILED after a restart" "$(aws s3api head-object --bucket rsrc --key lost/x.txt --query ReplicationStatus --output text 2>&1)" FAILED
check "COMPLETED after a restart" "$(aws s3api head-object --bucket rsrc --key f/multi.bin --query ReplicationStatus --output text 2>&1)" COMPLETED
# A target removed while its deliveries wait (ADR-0106 §6, the M15 exit review's B5): the far server stopped, a
# write waits for it; its target taken out of the file, the delivery fails as an unknown target's does, and nothing is
# dropped or left waiting.
kill "$remote"; wait "$remote" 2>/dev/null
aws s3api put-object --bucket rsrc --key f/waits.txt --body r1.txt > /dev/null 2>&1
sleep 2
check "a delivery waits for its target" "$(aws s3api head-object --bucket rsrc --key f/waits.txt --query ReplicationStatus --output text 2>&1)" PENDING
cp "$work/replication.targets" "$work/replication.targets.kept"
printf 'other http://127.0.0.1:1 AKIAOTHERTARGET00001 other/secret/0123456789abcdefgh\n' > "$work/replication.targets"
for i in $(seq 1 40); do grep -q "replication targets file reloaded" "$work/server.log" && break; sleep 0.25; done
check "the target taken out, without a restart" "$(grep -c 'replication targets file reloaded' "$work/server.log")" 1
for i in $(seq 1 300); do
    st=$(aws s3api head-object --bucket rsrc --key f/waits.txt --query ReplicationStatus --output text 2>/dev/null)
    [ "$st" = FAILED ] && break
    sleep 0.25
done
check "its waiting delivery fails as an unknown target's" "$st" FAILED
check "and none is dropped or left waiting" "$(stat eventsPending) $(stat eventsDropped)" "0 0"
cp "$work/replication.targets.kept" "$work/replication.targets"
aws s3api delete-bucket-replication --bucket rsrc > /dev/null 2>&1
kill "$remote" 2>/dev/null
for b in rsrc rdst; do
    for kind in Versions DeleteMarkers; do
        aws s3api list-object-versions --bucket $b --query "$kind[].[Key,VersionId]" --output text | while read -r k v; do
            [ "$k" = None ] && continue
            aws s3api delete-object --bucket $b --key "$k" --version-id "$v" > /dev/null 2>&1
        done
    done
done
for b in rsrc rdst rplain; do aws s3api delete-bucket --bucket $b > /dev/null 2>&1; done

# Inventory reports (ADR-0074): a "day" of 3 seconds here; a report of the smoke bucket into smokelogs.
check "inventory to a bucket that is not there" "$(code s3api put-bucket-inventory-configuration --bucket smoke --id daily --inventory-configuration '{"Id":"daily","IsEnabled":true,"Destination":{"S3BucketDestination":{"Bucket":"arn:aws:s3:::nobucket","Format":"CSV"}},"Schedule":{"Frequency":"Daily"},"IncludedObjectVersions":"Current"}')" InvalidArgument
check "parquet is not done" "$(code s3api put-bucket-inventory-configuration --bucket smoke --id daily --inventory-configuration '{"Id":"daily","IsEnabled":true,"Destination":{"S3BucketDestination":{"Bucket":"arn:aws:s3:::smokelogs","Format":"Parquet"}},"Schedule":{"Frequency":"Daily"},"IncludedObjectVersions":"Current"}')" NotImplemented
aws s3api put-bucket-inventory-configuration --bucket smoke --id daily --inventory-configuration '{"Id":"daily","IsEnabled":true,"Destination":{"S3BucketDestination":{"Bucket":"arn:aws:s3:::smokelogs","Format":"CSV","Prefix":"inv"}},"Schedule":{"Frequency":"Daily"},"IncludedObjectVersions":"Current","OptionalFields":["Size","ETag"]}' > /dev/null 2>&1 && pass "put-bucket-inventory-configuration" || fail "put-bucket-inventory-configuration"
check "get-bucket-inventory-configuration" "$(aws s3api get-bucket-inventory-configuration --bucket smoke --id daily --query InventoryConfiguration.Destination.S3BucketDestination.Prefix --output text 2>&1)" inv
check "list-bucket-inventory-configurations" "$(aws s3api list-bucket-inventory-configurations --bucket smoke --query 'length(InventoryConfigurationList)' --output text 2>&1)" 1
for i in $(seq 1 60); do
    m=$(aws s3api list-objects-v2 --bucket smokelogs --prefix inv/smoke/daily/ --query "Contents[?ends_with(Key, 'manifest.json')].Key | [0]" --output text 2>/dev/null)
    [ -n "$m" ] && [ "$m" != "None" ] && break
    sleep 0.25
done
check "a report is written" "$([ -n "$m" ] && [ "$m" != "None" ] && echo yes)" yes
# No more reports while this one is read: with a 3-second day, the next would land in the same minute's folder.
aws s3api delete-bucket-inventory-configuration --bucket smoke --id daily > /dev/null 2>&1
sleep 1
aws s3 cp "s3://smokelogs/$m" manifest.json > /dev/null 2>&1
aws s3 cp "s3://smokelogs/${m%manifest.json}manifest.checksum" manifest.checksum > /dev/null 2>&1
check "its manifest's checksum" "$(cat manifest.checksum)" "$(python3 -c 'import hashlib; print(hashlib.md5(open("manifest.json","rb").read()).hexdigest())')"
data=$(python3 -c 'import json,sys; print(json.load(open("manifest.json"))["files"][0]["key"])')
aws s3 cp "s3://smokelogs/$data" data.csv.gz > /dev/null 2>&1
rows=$(python3 -c 'import gzip; print(len(gzip.open("data.csv.gz").read().decode().splitlines()))')
check "its CSV, gzip, a row per object" "$rows" "$(aws s3api list-objects-v2 --bucket smoke --query 'length(Contents)' --output text)"
check "rows name the bucket, the key, the size and the ETag" "$(python3 -c 'import gzip,csv; r=list(csv.reader(gzip.open("data.csv.gz","rt"))); print(len(r[0]), r[0][0])')" "4 smoke"
check "deleted" "$(code s3api get-bucket-inventory-configuration --bucket smoke --id daily)" NoSuchConfiguration

# Static website hosting (ADR-0073): <bucket>.web.localhost is the bucket's website, anonymous, GET and HEAD.
aws s3api create-bucket --bucket site > /dev/null 2>&1
printf 'home' > home.html; printf 'docs' > docs.html; printf 'oops' > oops.html; printf 'plain' > plain.txt
aws s3 cp home.html s3://site/index.html > /dev/null 2>&1
aws s3 cp docs.html s3://site/docs/index.html > /dev/null 2>&1
aws s3 cp oops.html s3://site/error.html > /dev/null 2>&1
aws s3 cp plain.txt s3://site/plain.txt > /dev/null 2>&1
aws s3api put-object --bucket site --key moved --website-redirect-location /plain.txt > /dev/null 2>&1
aws s3api put-bucket-policy --bucket site --policy '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::site/*"}]}' > /dev/null 2>&1
aws s3api put-bucket-website --bucket site --website-configuration '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"error.html"},"RoutingRules":[{"Condition":{"KeyPrefixEquals":"old/"},"Redirect":{"ReplaceKeyPrefixWith":"docs/"}}]}' > /dev/null 2>&1 && pass "put-bucket-website" || fail "put-bucket-website"
check "get-bucket-website" "$(aws s3api get-bucket-website --bucket site --query IndexDocument.Suffix --output text 2>&1)" index.html
web="http://127.0.0.1:$port"
site() { curl -s -o site.body -w '%{http_code} %{redirect_url}' -H "Host: site.web.localhost:$port" "$@"; }
check "the site's index" "$(site "$web/") $(cat site.body)" "200  home"
check "a folder without its slash" "$(site "$web/docs")" "302 $web/docs/"
check "a folder's index" "$(site "$web/docs/") $(cat site.body)" "200  docs"
check "the error document" "$(site "$web/nothing") $(cat site.body)" "404  oops"
check "a routing rule" "$(site "$web/old/index.html")" "301 http://site.web.localhost:$port/docs/index.html"
check "an object's own redirect" "$(site "$web/moved")" "301 $web/plain.txt"
check "only GET and HEAD" "$(site -X DELETE "$web/plain.txt")" "405 "
check "the object is still there" "$(site "$web/plain.txt") $(cat site.body)" "200  plain"
aws s3api delete-bucket-website --bucket site > /dev/null 2>&1
check "no website after its deletion" "$(site "$web/" ; grep -c NoSuchWebsiteConfiguration site.body)" "404 1"
aws s3 rm --recursive s3://site/ > /dev/null 2>&1

# Directory buckets (ADR-0080): the CLI takes a session (CreateSession) before each bucket's calls, signed for s3express.
dir=data--local-az1--x-s3
# Through `localhost`, not 127.0.0.1: the AWS CRT (the CLI's transfer client on newer versions) puts a directory
# bucket only in the host name of its CreateSession, so it needs `<bucket>.localhost` (in CI's /etc/hosts).
dl() { AWS_ENDPOINT_URL="http://localhost:$port" aws "$@"; }
dirconf='Location={Type=AvailabilityZone,Name=local-az1},Bucket={DataRedundancy=SingleAvailabilityZone,Type=Directory}'
check "create a directory bucket" "$(aws s3api create-bucket --bucket "$dir" --create-bucket-configuration "$dirconf" --query BucketArn --output text 2>&1)" "arn:aws:s3express:us-east-1:000000000000:bucket/$dir"
# Another zone's bucket: the CLI's CreateSession for it finds no such bucket here, before its CreateBucket.
check "another zone" "$(code s3api create-bucket --bucket x--usw2-az1--x-s3 --create-bucket-configuration 'Location={Type=AvailabilityZone,Name=usw2-az1},Bucket={DataRedundancy=SingleAvailabilityZone,Type=Directory}')" NoSuchBucket
check "a directory bucket's name without its configuration" "$(code s3api create-bucket --bucket plain--local-az1--x-s3)" InvalidBucketName
check "list-directory-buckets" "$(aws s3api list-directory-buckets --query 'Buckets[].Name' --output text 2>&1)" "$dir"
check "not in list-buckets" "$(aws s3api list-buckets --query "length(Buckets[?Name=='$dir'])" 2>&1)" 0
printf 'in a directory' > dir.txt
aws s3api put-object --bucket "$dir" --key a/b.txt --body dir.txt > /dev/null 2>&1 && pass "a PUT with a session" || fail "a PUT with a session"
check "a GET with a session" "$(dl s3 cp "s3://$dir/a/b.txt" - 2>&1)" "in a directory"
mkdir -p dirtree/x && printf 1 > dirtree/one && printf 2 > dirtree/x/two
check "s3 cp --recursive" "$(dl s3 cp --recursive dirtree "s3://$dir/tree/" 2>&1 | grep -c upload:)" 2
check "and listed" "$(aws s3api list-objects-v2 --bucket "$dir" --prefix tree/ --query 'length(Contents)' 2>&1)" 2
read -r rk rs rt <<< "$(aws s3api create-session --bucket "$dir" --session-mode ReadOnly --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1)"
check "create-session gives a key" "${rk:0:4}" ASIA
express() { python3 -I "$here/s3_raw.py" express "$AWS_ENDPOINT_URL" "$@"; }
check "a ReadOnly session reads" "$(express "$rk" "$rs" "$rt" GET "/$dir/a/b.txt")" "200 in a directory"
check "but does not write" "$(express "$rk" "$rs" "$rt" PUT "/$dir/a/no.txt" | cut -d' ' -f1)" 403
aws s3api create-bucket --bucket other--local-az1--x-s3 --create-bucket-configuration "$dirconf" > /dev/null 2>&1
check "a directory bucket takes no transition (M12 review A2)" "$(code s3api put-bucket-lifecycle-configuration --bucket other--local-az1--x-s3 --lifecycle-configuration '{"Rules":[{"ID":"t","Status":"Enabled","Filter":{"Prefix":""},"Transitions":[{"Days":30,"StorageClass":"STANDARD_IA"}]}]}')" NotImplemented
check "nor reach another directory bucket" "$(express "$rk" "$rs" "$rt" GET "/other--local-az1--x-s3?list-type=2" | cut -d' ' -f1)" 403
aws s3api delete-bucket --bucket other--local-az1--x-s3 > /dev/null 2>&1
check "a changed token" "$(express "$rk" "$rs" "${rt%????}AAAA" GET "/$dir/a/b.txt" | cut -d' ' -f1)" 400
check "s3express on a general-purpose bucket" "$(express "" "" "" GET "/smoke?list-type=2" | cut -d' ' -f1)" 400
check "nor makes one" "$(express "" "" "" PUT "/plain-by-express" | cut -d' ' -f1)" 400
# A session reaches its bucket only (the M8 exit review's B1 to B3, B7).
read -r wk ws wt <<< "$(aws s3api create-session --bucket "$dir" --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1)"
check "a session does not reach S3 Control" "$(express "$wk" "$ws" "$wt" GET "/v20180820/accesspoint" x-amz-account-id:000000000000 | cut -d' ' -f1)" 403
check "nor list buckets" "$(express "$wk" "$ws" "$wt" GET "/" | cut -d' ' -f1)" 403
check "nor copy from another bucket" "$(express "$wk" "$ws" "$wt" PUT "/$dir/copied" x-amz-copy-source:smoke/small.txt | cut -d' ' -f1)" 403
check "a token without a signature" "$(curl -s -o /dev/null -w '%{http_code}' -H "x-amz-s3session-token: $wt" "$AWS_ENDPOINT_URL/$dir/a/b.txt")" 403
check "the session's encryption is the bucket's" "$(aws s3api create-session --bucket "$dir" --query ServerSideEncryption --output text 2>&1)" AES256
check "and objects are sealed with it" "$(aws s3api head-object --bucket "$dir" --key a/b.txt --query ServerSideEncryption --output text 2>&1)" AES256
check "no other encryption" "$(code s3api put-object --bucket "$dir" --key t --body dir.txt --server-side-encryption aws:kms)" InvalidArgument
# A bucket policy of s3express actions (B4, B5): a key denied CreateSession gets none, and its sessions stop.
denyme='{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":{"AWS":"arn:aws:iam:::user/'"$AWS_ACCESS_KEY_ID"'"},"Action":"s3express:CreateSession","Resource":"arn:aws:s3express:us-east-1:000000000000:bucket/'"$dir"'"}]}'
check "an s3express policy is taken" "$(aws s3api put-bucket-policy --bucket "$dir" --policy "$denyme" 2>&1; echo $?)" 0
check "CreateSession denied by it" "$(code s3api create-session --bucket "$dir")" AccessDenied
check "and a session made before" "$(express "$wk" "$ws" "$wt" GET "/$dir/a/b.txt" | cut -d' ' -f1)" 403
# The CLI takes a session for every call, which the policy denies: the key removes it without one.
check "the policy removed by the key itself" "$(express "" "" "" DELETE "/$dir?policy" | cut -d' ' -f1)" 204
check "the policy gone, the session again" "$(express "$wk" "$ws" "$wt" GET "/$dir/a/b.txt")" "200 in a directory"
# What S3 shows and takes for a directory bucket's objects (A1, A2, A4, A7).
check "versionId null" "$(aws s3api head-object --bucket "$dir" --key a/b.txt --version-id null --query ContentLength --output text 2>&1)" 14
check "another versionId" "$(code s3api head-object --bucket "$dir" --key a/b.txt --version-id 3HL4kqtJlcpXroDTDmJ.rmSpXd3dIbrHY)" 400
check "the storage class" "$(aws s3api list-objects-v2 --bucket "$dir" --prefix a/ --query 'Contents[0].StorageClass' --output text 2>&1)" EXPRESS_ONEZONE
check "head-bucket's zone" "$(aws s3api head-bucket --bucket "$dir" --query '[BucketLocationType,BucketLocationName]' --output text 2>&1)" "AvailabilityZone	local-az1"
aws s3api put-object --bucket smoke --key tagged.txt --body dir.txt --tagging a=b > /dev/null 2>&1
check "a tagged object is not copied in" "$(code s3api copy-object --bucket "$dir" --key tagged.txt --copy-source smoke/tagged.txt)" NotImplemented
check "but is with its tags replaced by none" "$(aws s3api copy-object --bucket "$dir" --key tagged.txt --copy-source smoke/tagged.txt --tagging-directive REPLACE > /dev/null 2>&1; echo $?)" 0
aws s3api delete-object --bucket smoke --key tagged.txt > /dev/null 2>&1
check "delete-objects" "$(aws s3api delete-objects --bucket "$dir" --delete 'Objects=[{Key=tagged.txt},{Key=tree/one}]' --query 'length(Deleted)' 2>&1)" 2
# RenameObject (ADR-0081): one record moves the object, its ETag and dates kept.
aws s3api put-object --bucket "$dir" --key ren/src.txt --body dir.txt > /dev/null 2>&1
renetag=$(aws s3api head-object --bucket "$dir" --key ren/src.txt --query ETag --output text 2>&1)
check "rename-object" "$(aws s3api rename-object --bucket "$dir" --key ren/dst.txt --rename-source "$dir/ren/src.txt" > /dev/null 2>&1; echo $?)" 0
check "the object under its new key" "$(aws s3api get-object --bucket "$dir" --key ren/dst.txt dir.out --query ETag --output text 2>&1; cat dir.out)" "$renetag
in a directory"
check "and not under its old one" "$(code s3api head-object --bucket "$dir" --key ren/src.txt)" 404
aws s3api put-object --bucket "$dir" --key ren/other.txt --body dir.txt > /dev/null 2>&1
check "If-None-Match * on a destination that exists" "$(code s3api rename-object --bucket "$dir" --key ren/dst.txt --rename-source /ren/other.txt --destination-if-none-match '*')" PreconditionFailed
check "a source condition" "$(code s3api rename-object --bucket "$dir" --key ren/new.txt --rename-source /ren/other.txt --source-if-match '"0123"')" PreconditionFailed
check "a missing source" "$(code s3api rename-object --bucket "$dir" --key ren/new.txt --rename-source /ren/none.txt)" NoSuchKey
check "a client token" "$(aws s3api rename-object --bucket "$dir" --key ren/third.txt --rename-source ren/other.txt --client-token smoke-1 > /dev/null 2>&1; echo $?)" 0
check "the same request again" "$(aws s3api rename-object --bucket "$dir" --key ren/third.txt --rename-source ren/other.txt --client-token smoke-1 > /dev/null 2>&1; echo $?)" 0
check "the token for another rename" "$(code s3api rename-object --bucket "$dir" --key ren/fourth.txt --rename-source ren/third.txt --client-token smoke-1)" IdempotencyParameterMismatch
check "a ReadOnly session does not rename" "$(express "$rk" "$rs" "$rt" PUT "/$dir/ren/x.txt?renameObject" x-amz-rename-source:/ren/third.txt | cut -d' ' -f1)" 403
check "nor a general-purpose bucket" "$(code s3api rename-object --bucket smoke --key a --rename-source smoke/small.txt)" NotImplemented
# A directory bucket's ETags are not MD5s (ADR-0080 §7), and conditions use them.
detag=$(aws s3api head-object --bucket "$dir" --key a/b.txt --query ETag --output text 2>&1)
check "an ETag that is not the MD5" "$([ "$detag" != "\"$(md5 -q dir.txt 2>/dev/null || md5sum dir.txt | cut -d' ' -f1)\"" ] && echo "${#detag}")" 34
check "If-Match with it" "$(aws s3api get-object --bucket "$dir" --key a/b.txt --if-match "$detag" dir.out --query ETag --output text 2>&1)" "$detag"
check "listed with it" "$(aws s3api list-objects-v2 --bucket "$dir" --prefix a/ --query 'Contents[0].ETag' --output text 2>&1)" "$detag"
upload=$(aws s3api create-multipart-upload --bucket "$dir" --key pending/x/part.bin --query UploadId --output text 2>&1)
check "an upload in progress is a directory" "$(aws s3api list-objects-v2 --bucket "$dir" --delimiter / --query 'CommonPrefixes[].Prefix' --output text 2>&1)" "a/	pending/	ren/	tree/"
aws s3api abort-multipart-upload --bucket "$dir" --key pending/x/part.bin --upload-id "$upload" > /dev/null 2>&1
check "and is not once it ends" "$(aws s3api list-objects-v2 --bucket "$dir" --delimiter / --query 'CommonPrefixes[].Prefix' --output text 2>&1)" "a/	ren/	tree/"

# A directory bucket's access point (ADR-0082): made with a scope, then requests through it with its sessions.
door=door--local-az1--xa-s3
check "create-access-point for a directory bucket" "$(ctl create-access-point --name "$door" --bucket "$dir" --scope 'Prefixes=[pub/*],Permissions=[GetObject,PutObject,ListBucket]' --query '[Alias,AccessPointArn]' --output text 2>&1)" "$door	arn:aws:s3express:us-east-1:000000000000:accesspoint/$door"
check "get-access-point-scope" "$(ctl get-access-point-scope --name "$door" --query '[Scope.Prefixes[0],length(Scope.Permissions)]' --output text 2>&1)" "pub/*	3"
check "list-access-points-for-directory-buckets" "$(ctl list-access-points-for-directory-buckets --directory-bucket "$dir" --query 'AccessPointList[].Name' --output text 2>&1)" "$door"
check "not in list-access-points" "$(ctl list-access-points --query "length(AccessPointList[?Name=='$door'])" 2>&1)" 0
check "a general-purpose name for it" "$(apcode s3control create-access-point --account-id 000000000000 --name plain-door --bucket "$dir")" InvalidRequest
check "a scope on a general-purpose bucket's" "$(apcode s3control put-access-point-scope --account-id 000000000000 --name smoke-ap --scope 'Prefixes=[a/]')" InvalidRequest
check "a PUT through it, in its scope" "$(aws s3api put-object --bucket "$door" --key pub/door.txt --body dir.txt > /dev/null 2>&1; echo $?)" 0
check "read through the bucket" "$(aws s3api get-object --bucket "$dir" --key pub/door.txt dir.out > /dev/null 2>&1; cat dir.out)" "in a directory"
check "a GET through it" "$(aws s3api get-object --bucket "$door" --key pub/door.txt dir.out > /dev/null 2>&1; cat dir.out)" "in a directory"
check "a listing within its prefix" "$(aws s3api list-objects-v2 --bucket "$door" --prefix pub/ --query 'Contents[].Key' --output text 2>&1)" "pub/door.txt"
check "a key outside its scope" "$(code s3api get-object --bucket "$door" --key a/b.txt dir.out)" AccessDenied
check "a permission outside its scope" "$(code s3api delete-object --bucket "$door" --key pub/door.txt)" AccessDenied
check "a listing outside its prefix" "$(code s3api list-objects-v2 --bucket "$door" --prefix a/)" AccessDenied
read -r dk ds dt <<< "$(aws s3api create-session --bucket "$door" --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1)"
check "its session through it" "$(express "$dk" "$ds" "$dt" GET "/$door/pub/door.txt")" "200 in a directory"
check "but not around it, to its bucket" "$(express "$dk" "$ds" "$dt" GET "/$dir/a/b.txt" | cut -d' ' -f1)" 403
check "and a bucket's session not through it" "$(express "$wk" "$ws" "$wt" GET "/$door/pub/door.txt" | cut -d' ' -f1)" 403
check "no anonymous request" "$(curl -s -o /dev/null -w '%{http_code}' "$AWS_ENDPOINT_URL/$door/pub/door.txt")" 403
check "the scope widened" "$(ctl put-access-point-scope --name "$door" --scope 'Permissions=[GetObject,DeleteObject]' > /dev/null 2>&1; aws s3api delete-object --bucket "$door" --key pub/door.txt > /dev/null 2>&1; echo $?)" 0
check "then deleted" "$(ctl delete-access-point-scope --name "$door" > /dev/null 2>&1; ctl get-access-point-scope --name "$door" --query 'length(Scope.Permissions || `[]`)' 2>&1)" 0
door_policy='{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":"*","Action":"s3express:CreateSession","Resource":"arn:aws:s3express:us-east-1:000000000000:accesspoint/'"$door"'"}]}'
check "a policy of it" "$(ctl put-access-point-policy --name "$door" --policy "$door_policy" > /dev/null 2>&1; echo $?)" 0
check "denies its sessions" "$(code s3api create-session --bucket "$door")" AccessDenied
check "and the one it gave" "$(express "$dk" "$ds" "$dt" GET "/$door/a/b.txt" | cut -d' ' -f1)" 403
check "delete-access-point" "$(ctl delete-access-point --name "$door" > /dev/null 2>&1; ctl list-access-points-for-directory-buckets --query 'length(AccessPointList)' 2>&1)" 0

# What a directory bucket does not take (ADR-0080 §6), as S3 refuses it.
check "no versioning" "$(code s3api put-bucket-versioning --bucket "$dir" --versioning-configuration Status=Enabled)" NotImplemented
check "no object tags" "$(code s3api put-object --bucket "$dir" --key t --body dir.txt --tagging a=b)" NotImplemented
check "no ListObjects v1" "$(code s3api list-objects --bucket "$dir")" NotImplemented
check "a prefix ends in /" "$(code s3api list-objects-v2 --bucket "$dir" --prefix tr)" InvalidArgument
check "no STANDARD storage class" "$(code s3api put-object --bucket "$dir" --key t --body dir.txt --storage-class STANDARD)" InvalidArgument
check "a policy is taken" "$(aws s3api put-bucket-policy --bucket "$dir" --policy '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::'"$dir"'/secret/*"}]}' 2>&1; echo $?)" 0
dl s3 rm --recursive "s3://$dir/" > /dev/null 2>&1
aws s3api delete-bucket --bucket "$dir" > /dev/null 2>&1 && pass "delete the directory bucket" || fail "delete the directory bucket"

# S3 Tables (ADR-0083): table buckets, namespaces and tables through `aws s3tables`; the warehouse through S3.
tarn=$(aws s3tables create-table-bucket --name smoke-tables --query arn --output text 2>&1)
check "create-table-bucket" "$tarn" "arn:aws:s3tables:us-east-1:000000000000:bucket/smoke-tables"
check "a name twice" "$(code s3tables create-table-bucket --name smoke-tables)" ConflictException
check "list-table-buckets" "$(aws s3tables list-table-buckets --query 'tableBuckets[].name' --output text 2>&1)" smoke-tables
check "not in list-buckets" "$(aws s3api list-buckets --query "length(Buckets[?ends_with(Name, '--table-s3')])" 2>&1)" 0
aws s3tables create-namespace --table-bucket-arn "$tarn" --namespace sales > /dev/null 2>&1
check "list-namespaces" "$(aws s3tables list-namespaces --table-bucket-arn "$tarn" --query 'namespaces[].namespace[0]' --output text 2>&1)" sales
check "create-table" "$(aws s3tables create-table --table-bucket-arn "$tarn" --namespace sales --name orders --format ICEBERG --query 'tableARN' --output text 2>&1 | grep -c ':bucket/smoke-tables/table/')" 1
read -r twh ttok <<< "$(aws s3tables get-table --table-bucket-arn "$tarn" --namespace sales --name orders --query '[warehouseLocation,versionToken]' --output text 2>&1)"
twb=${twh#s3://}; twb=${twb%%/*}; tpre=${twh#s3://*/}
check "its warehouse is a table bucket's" "${twb: -10}" "--table-s3"
aws s3api put-object --bucket "$twb" --key "$tpre/metadata/00001-a.metadata.json" --body dir.txt > /dev/null 2>&1 && pass "an engine writes in the warehouse" || fail "an engine writes in the warehouse"
check "update-table-metadata-location" "$(aws s3tables update-table-metadata-location --table-bucket-arn "$tarn" --namespace sales --name orders --version-token "$ttok" --metadata-location "$twh/metadata/00001-a.metadata.json" --query metadataLocation --output text 2>&1)" "$twh/metadata/00001-a.metadata.json"
check "with a token no longer current" "$(code s3tables update-table-metadata-location --table-bucket-arn "$tarn" --namespace sales --name orders --version-token "$ttok" --metadata-location "$twh/metadata/00002-b.metadata.json")" ConflictException
check "outside its warehouse" "$(code s3tables update-table-metadata-location --table-bucket-arn "$tarn" --namespace sales --name orders --version-token "$ttok" --metadata-location s3://elsewhere/x.metadata.json)" BadRequestException
check "the catalog is not S3's" "$(code s3api get-object --bucket "$twb" --key .s3tables/bucket dir.out)" AccessDenied
# M9's exit review: no way into the catalog or out of it by S3's other calls (B1 to B3).
check "no form upload into a warehouse" "$(curl -s -o /dev/null -w '%{http_code}' --form-string 'key=.s3tables/tables/sales/evil' -F 'file=@dir.txt' "$AWS_ENDPOINT_URL/$twb")" 403
check "nor a copy out of its catalog" "$(code s3api copy-object --bucket smoke --key stolen --copy-source "$twb/.s3tables/tables/sales/orders")" AccessDenied
check "nor a part copied out of it" "$(up=$(aws s3api create-multipart-upload --bucket smoke --key stolen-part --query UploadId --output text 2>&1); code s3api upload-part-copy --bucket smoke --key stolen-part --upload-id "$up" --part-number 1 --copy-source "$twb/.s3tables/tables/sales/orders")" AccessDenied
check "no access logs into a warehouse" "$(code s3api put-bucket-logging --bucket smoke --bucket-logging-status "{\"LoggingEnabled\":{\"TargetBucket\":\"$twb\",\"TargetPrefix\":\".s3tables/namespaces/\"}}")" InvalidTargetBucketForLogging
check "no inventory into a warehouse" "$(code s3api put-bucket-inventory-configuration --bucket smoke --id inv-t --inventory-configuration "{\"Id\":\"inv-t\",\"IsEnabled\":true,\"IncludedObjectVersions\":\"Current\",\"Schedule\":{\"Frequency\":\"Daily\"},\"Destination\":{\"S3BucketDestination\":{\"Bucket\":\"arn:aws:s3:::$twb\",\"Format\":\"CSV\",\"Prefix\":\".s3tables\"}}}")" InvalidArgument
check "no access point on a warehouse" "$(apcode s3control create-access-point --account-id 000000000000 --name smoke-tables-ap --bucket "$twb")" InvalidRequest
# A body is read only for a request one of the server's keys signed (B5): an unknown key's is refused before it.
check "an unknown key's body is not read" "$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "x-amz-date: $(date -u +%Y%m%dT%H%M%SZ)" -H "Authorization: AWS4-HMAC-SHA256 Credential=NOKEY/$(date -u +%Y%m%d)/us-east-1/s3tables/aws4_request, SignedHeaders=host;x-amz-date, Signature=00" --data-binary @dir.txt "$AWS_ENDPOINT_URL/buckets")" 403
# The Iceberg catalog's errors are in its shape (C3), a bad signature's too.
check "an Iceberg error in Iceberg's shape" "$(curl -s --aws-sigv4 "aws:amz:us-east-1:s3tables" --user "$AWS_ACCESS_KEY_ID:wrong" "$AWS_ENDPOINT_URL/iceberg/v1/config?warehouse=$tarn" | python3 -I -c 'import json,sys; e=json.load(sys.stdin)["error"]; print(e["code"], e["type"])')" "403 ForbiddenException"
# GetTable names its namespace's id (C9); a rename names something new.
check "get-table's namespaceId" "$(aws s3tables get-table --table-bucket-arn "$tarn" --namespace sales --name orders --query namespaceId --output text 2>&1)" "$(aws s3tables get-namespace --table-bucket-arn "$tarn" --namespace sales --query namespaceId --output text 2>&1)"
check "a rename to nothing new" "$(code s3tables rename-table --table-bucket-arn "$tarn" --namespace sales --name orders)" BadRequestException
check "a gzipped metadata location" "$(code s3tables update-table-metadata-location --table-bucket-arn "$tarn" --namespace sales --name orders --version-token "$ttok" --metadata-location "$twh/metadata/00002-b.metadata.json.gz")" BadRequestException
# Policies for S3 Tables (ADR-0084): a table bucket's Deny stops a key; a table's stops its data through S3.
check "a key outside every table" "$(code s3api put-object --bucket "$twb" --key loose.txt --body dir.txt)" AccessDenied
tpol="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Principal\":{\"AWS\":\"arn:aws:iam:::user/$AWS_ACCESS_KEY_ID\"},\"Action\":\"s3tables:DeleteTable\",\"Resource\":\"$tarn/table/*\"}]}"
aws s3tables put-table-bucket-policy --table-bucket-arn "$tarn" --resource-policy "$tpol" > /dev/null 2>&1 && pass "put-table-bucket-policy" || fail "put-table-bucket-policy"
check "get-table-bucket-policy" "$(aws s3tables get-table-bucket-policy --table-bucket-arn "$tarn" --query resourcePolicy --output text 2>&1)" "$tpol"
check "its Deny refuses the key" "$(code s3tables delete-table --table-bucket-arn "$tarn" --namespace sales --name orders)" ForbiddenException
check "an S3 action in it" "$(code s3tables put-table-bucket-policy --table-bucket-arn "$tarn" --resource-policy '{"Statement":{"Effect":"Deny","Principal":"*","Action":"s3:GetObject","Resource":"*"}}')" BadRequestException
aws s3tables put-table-policy --table-bucket-arn "$tarn" --namespace sales --name orders --resource-policy "{\"Statement\":{\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3tables:GetTableData\",\"Resource\":\"$tarn/table/*\"}}" > /dev/null 2>&1 && pass "put-table-policy" || fail "put-table-policy"
check "its Deny refuses the table's data" "$(code s3api get-object --bucket "$twb" --key "$tpre/metadata/00001-a.metadata.json" dir.out)" AccessDenied
aws s3api put-object --bucket "$twb" --key "$tpre/data/w.parquet" --body dir.txt > /dev/null 2>&1 && pass "writing it is another action" || fail "writing it is another action"
aws s3tables delete-table-policy --table-bucket-arn "$tarn" --namespace sales --name orders > /dev/null 2>&1
aws s3api get-object --bucket "$twb" --key "$tpre/metadata/00001-a.metadata.json" dir.out > /dev/null 2>&1 && pass "the table's data after its policy" || fail "the table's data after its policy"
# A Deny of everything: the key keeps its policy calls (it cannot lock itself out); the Iceberg catalog refuses in its shape.
aws s3tables put-table-bucket-policy --table-bucket-arn "$tarn" --resource-policy "{\"Statement\":{\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3tables:*\",\"Resource\":[\"$tarn\",\"$tarn/table/*\"]}}" > /dev/null 2>&1
check "everything refused" "$(code s3tables get-table --table-bucket-arn "$tarn" --namespace sales --name orders)" ForbiddenException
check "the Iceberg catalog too" "$(curl -s --aws-sigv4 "aws:amz:us-east-1:s3tables" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" "$AWS_ENDPOINT_URL/iceberg/v1/config?warehouse=$tarn" | python3 -I -c 'import json,sys; e=json.load(sys.stdin)["error"]; print(e["code"], e["type"])')" "403 ForbiddenException"
aws s3tables delete-table-bucket-policy --table-bucket-arn "$tarn" > /dev/null 2>&1 && pass "but not its policy calls" || fail "but not its policy calls"
check "no policy now" "$(code s3tables get-table-bucket-policy --table-bucket-arn "$tarn")" NotFoundException
check "nor is the warehouse bucket" "$(code s3api delete-bucket --bucket "$twb")" NotImplemented
check "a --table-s3 name for a bucket" "$(code s3api create-bucket --bucket mine--table-s3)" InvalidBucketName
aws s3tables rename-table --table-bucket-arn "$tarn" --namespace sales --name orders --new-name orders_v2 > /dev/null 2>&1
check "rename-table" "$(aws s3tables list-tables --table-bucket-arn "$tarn" --namespace sales --query 'tables[].name' --output text 2>&1)" orders_v2
check "a namespace with tables" "$(code s3tables delete-namespace --table-bucket-arn "$tarn" --namespace sales)" ConflictException
# Maintenance (ADR-0086): its configurations through the CLI; compaction (ADR-0098) is taken.
aws s3tables put-table-bucket-maintenance-configuration --table-bucket-arn "$tarn" --type icebergUnreferencedFileRemoval --value 'status=enabled,settings={icebergUnreferencedFileRemoval={unreferencedDays=4,nonCurrentDays=10}}' > /dev/null 2>&1 && pass "put-table-bucket-maintenance-configuration" || fail "put-table-bucket-maintenance-configuration"
check "get-table-bucket-maintenance-configuration" "$(aws s3tables get-table-bucket-maintenance-configuration --table-bucket-arn "$tarn" --query 'configuration.icebergUnreferencedFileRemoval.settings.icebergUnreferencedFileRemoval.unreferencedDays' --output text 2>&1)" 4
aws s3tables put-table-maintenance-configuration --table-bucket-arn "$tarn" --namespace sales --name orders_v2 --type icebergCompaction --value 'status=enabled,settings={icebergCompaction={targetFileSizeMB=128}}' > /dev/null 2>&1 && pass "compaction's configuration taken" || fail "compaction's configuration taken"
check "get-table-maintenance-job-status" "$(aws s3tables get-table-maintenance-job-status --table-bucket-arn "$tarn" --namespace sales --name orders_v2 --query 'status.icebergCompaction.status' --output text 2>&1)" Not_Yet_Run
aws s3tables delete-table --table-bucket-arn "$tarn" --namespace sales --name orders_v2 > /dev/null 2>&1
check "delete-table removes its files" "$(aws s3api list-objects-v2 --bucket "$twb" --prefix "$tpre/" --query 'length(Contents || `[]`)' 2>&1)" 0
aws s3tables delete-namespace --table-bucket-arn "$tarn" --namespace sales > /dev/null 2>&1
aws s3tables delete-table-bucket --table-bucket-arn "$tarn" > /dev/null 2>&1 && pass "delete-table-bucket" || fail "delete-table-bucket"
# S3 Tables' tags, storage class and encryption (ADR-0126) through `aws s3tables`: each set, read and removed.
karn=arn:aws:kms:us-east-1:000000000000:key/orders
carn=$(aws s3tables create-table-bucket --name smoke-config --tags team=data --storage-class-configuration storageClass=INTELLIGENT_TIERING --encryption-configuration "sseAlgorithm=aws:kms,kmsKeyArn=$karn" --query arn --output text 2>&1)
check "create-table-bucket with its settings" "$carn" "arn:aws:s3tables:us-east-1:000000000000:bucket/smoke-config"
check "list-tags-for-resource" "$(aws s3tables list-tags-for-resource --resource-arn "$carn" --query tags.team --output text 2>&1)" data
aws s3tables tag-resource --resource-arn "$carn" --tags env=test > /dev/null 2>&1 && pass "tag-resource" || fail "tag-resource"
aws s3tables untag-resource --resource-arn "$carn" --tag-keys team > /dev/null 2>&1 && pass "untag-resource" || fail "untag-resource"
check "its tags after" "$(aws s3tables list-tags-for-resource --resource-arn "$carn" --output json 2>&1 | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["tags"])')" "{'env': 'test'}"
check "an aws: tag" "$(code s3tables tag-resource --resource-arn "$carn" --tags aws:x=y)" BadRequestException
# aws:TagKeys and aws:RequestTag in its policy (ADR-0126 §1): a Deny of tagging with the key `frozen`, or setting `env`
# to `prod`; other tags are taken.
aws s3tables put-table-bucket-policy --table-bucket-arn "$carn" --resource-policy "{\"Statement\":[{\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3tables:TagResource\",\"Resource\":\"$carn\",\"Condition\":{\"ForAnyValue:StringEquals\":{\"aws:TagKeys\":\"frozen\"}}},{\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3tables:TagResource\",\"Resource\":\"$carn\",\"Condition\":{\"StringEquals\":{\"aws:RequestTag/env\":\"prod\"}}}]}" > /dev/null 2>&1 && pass "a policy on the tags a call sets" || fail "a policy on the tags a call sets"
check "aws:TagKeys denies its key" "$(code s3tables tag-resource --resource-arn "$carn" --tags frozen=1)" ForbiddenException
check "aws:RequestTag denies its value" "$(code s3tables tag-resource --resource-arn "$carn" --tags env=prod)" ForbiddenException
aws s3tables tag-resource --resource-arn "$carn" --tags env=test > /dev/null 2>&1 && pass "and takes the others" || fail "and takes the others"
aws s3tables delete-table-bucket-policy --table-bucket-arn "$carn" > /dev/null 2>&1
check "get-table-bucket-storage-class" "$(aws s3tables get-table-bucket-storage-class --table-bucket-arn "$carn" --query storageClassConfiguration.storageClass --output text 2>&1)" INTELLIGENT_TIERING
check "get-table-bucket-encryption" "$(aws s3tables get-table-bucket-encryption --table-bucket-arn "$carn" --query '[encryptionConfiguration.sseAlgorithm,encryptionConfiguration.kmsKeyArn]' --output text 2>&1 | tr '\t' ' ')" "aws:kms $karn"
check "a KMS key there is not" "$(code s3tables put-table-bucket-encryption --table-bucket-arn "$carn" --encryption-configuration sseAlgorithm=aws:kms,kmsKeyArn=arn:aws:kms:us-east-1:000000000000:key/nobody)" BadRequestException
aws s3tables create-namespace --table-bucket-arn "$carn" --namespace ns > /dev/null 2>&1
ctarn=$(aws s3tables create-table --table-bucket-arn "$carn" --namespace ns --name t --format ICEBERG --tags stage=raw --query tableARN --output text 2>&1)
check "a table's tags, by its ARN" "$(aws s3tables list-tags-for-resource --resource-arn "$ctarn" --query tags.stage --output text 2>&1)" raw
check "get-table-storage-class: its bucket's" "$(aws s3tables get-table-storage-class --table-bucket-arn "$carn" --namespace ns --name t --query storageClassConfiguration.storageClass --output text 2>&1)" INTELLIGENT_TIERING
check "get-table-encryption: its bucket's" "$(aws s3tables get-table-encryption --table-bucket-arn "$carn" --namespace ns --name t --query encryptionConfiguration.sseAlgorithm --output text 2>&1)" aws:kms
aws s3tables put-table-bucket-storage-class --table-bucket-arn "$carn" --storage-class-configuration storageClass=STANDARD > /dev/null 2>&1 && pass "put-table-bucket-storage-class" || fail "put-table-bucket-storage-class"
check "the table's kept from its create" "$(aws s3tables get-table-storage-class --table-bucket-arn "$carn" --namespace ns --name t --query storageClassConfiguration.storageClass --output text 2>&1)" INTELLIGENT_TIERING
aws s3tables delete-table-bucket-encryption --table-bucket-arn "$carn" > /dev/null 2>&1 && pass "delete-table-bucket-encryption" || fail "delete-table-bucket-encryption"
check "none after" "$(code s3tables get-table-bucket-encryption --table-bucket-arn "$carn")" NotFoundException
check "the table's kept" "$(aws s3tables get-table-encryption --table-bucket-arn "$carn" --namespace ns --name t --query encryptionConfiguration.sseAlgorithm --output text 2>&1)" aws:kms
aws s3tables put-table-bucket-encryption --table-bucket-arn "$carn" --encryption-configuration sseAlgorithm=AES256 > /dev/null 2>&1 && pass "put-table-bucket-encryption" || fail "put-table-bucket-encryption"
# Metrics and record expiration (ADR-0130 §4, §5): metrics kept, an id answered, the bucket's requests counted in the
# stats endpoint; record expiration is AWS's for its managed tables.
check "no metrics configuration at first" "$(code s3tables get-table-bucket-metrics-configuration --table-bucket-arn "$carn")" NotFoundException
aws s3tables put-table-bucket-metrics-configuration --table-bucket-arn "$carn" > /dev/null 2>&1 && pass "put-table-bucket-metrics-configuration" || fail "put-table-bucket-metrics-configuration"
check "get-table-bucket-metrics-configuration" "$(aws s3tables get-table-bucket-metrics-configuration --table-bucket-arn "$carn" --query tableBucketARN --output text 2>&1)" "$carn"
check "its requests counted in the stats" "$(curl -s --aws-sigv4 "aws:amz:us-east-1:s3" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" "$AWS_ENDPOINT_URL/_cosmostore/stats" | python3 -I -c 'import json,sys; t=[b for b in json.load(sys.stdin)["tableBuckets"] if b["name"]=="smoke-config"]; print(len(t) == 1 and t[0]["requests"] > 5 and t[0]["clientErrors"] >= 1)')" True
aws s3tables delete-table-bucket-metrics-configuration --table-bucket-arn "$carn" > /dev/null 2>&1 && pass "delete-table-bucket-metrics-configuration" || fail "delete-table-bucket-metrics-configuration"
check "and not counted in the stats" "$(curl -s --aws-sigv4 "aws:amz:us-east-1:s3" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" "$AWS_ENDPOINT_URL/_cosmostore/stats" | python3 -I -c 'import json,sys; print([b["name"] for b in json.load(sys.stdin)["tableBuckets"]])')" "[]"
check "record expiration: AWS's managed tables only" "$(code s3tables get-table-record-expiration-configuration --table-arn "$ctarn")" MethodNotAllowedException
check "nor put" "$(code s3tables put-table-record-expiration-configuration --table-arn "$ctarn" --value 'status=enabled,settings={days=30}')" MethodNotAllowedException
check "nor its job's status" "$(code s3tables get-table-record-expiration-job-status --table-arn "$ctarn")" MethodNotAllowedException
aws s3tables delete-table --table-bucket-arn "$carn" --namespace ns --name t > /dev/null 2>&1
check "a table's tags gone with it" "$(code s3tables list-tags-for-resource --resource-arn "$ctarn")" NotFoundException
aws s3tables delete-namespace --table-bucket-arn "$carn" --namespace ns > /dev/null 2>&1
aws s3tables delete-table-bucket --table-bucket-arn "$carn" > /dev/null 2>&1 && pass "and the bucket with its settings deleted" || fail "and the bucket with its settings deleted"
check "gone" "$(aws s3tables list-table-buckets --query 'length(tableBuckets)' 2>&1)" 0
# The Iceberg REST catalog through PyIceberg (ADR-0083 §5), when ICEBERG_PYTHON names a Python that has it.
if [ -n "${ICEBERG_PYTHON:-}" ]; then
    if "$ICEBERG_PYTHON" "$here/iceberg_check.py" "http://127.0.0.1:$port" > iceberg.out 2>&1; then
        pass "PyIceberg: $(grep -c '^ok' iceberg.out) checks"
    else
        fail "PyIceberg"; cat iceberg.out
    fi
else
    echo "skip PyIceberg (set ICEBERG_PYTHON to a Python with pyiceberg[pyarrow] and boto3)"
fi
# Table maintenance (ADR-0086) through PyIceberg, on a server of its own whose day is 12 s (an hour is 0.5 s).
if [ -n "${ICEBERG_PYTHON:-}" ]; then
    maintport=$((port + 5))
    "$bin" serve "$work/maint-store" "$maintport" "$work/credentials" localhost --tables-day-seconds 12 2>> "$work/maint.log" &
    maint=$!
    sleep 1
    if "$ICEBERG_PYTHON" "$here/maintenance_check.py" "http://127.0.0.1:$maintport" 12 > maintenance.out 2>&1; then
        pass "table maintenance: $(grep -c '^ok' maintenance.out) checks"
    else
        fail "table maintenance"; cat maintenance.out
    fi
    kill "$maint" 2>/dev/null
    # Compaction (ADR-0098) through PyIceberg, on another server of its own.
    compactport=$((port + 7))
    "$bin" serve "$work/compact-store" "$compactport" "$work/credentials" localhost --tables-day-seconds 12 2>> "$work/compact.log" &
    compactsrv=$!
    sleep 1
    if "$ICEBERG_PYTHON" "$here/compaction_check.py" "http://127.0.0.1:$compactport" 12 > compaction.out 2>&1; then
        pass "compaction: $(grep -c '^ok' compaction.out) checks"
    else
        fail "compaction"; cat compaction.out
    fi
    kill "$compactsrv" 2>/dev/null
fi

# Users (ADR-0088): a server of its own with a users file, so the rotation checks above keep their own file.
usersport=$((port + 6))
printf '%s\n' "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" "AKIAUSERREADER000001 reader/secret/0123456789abcdefgh" \
    "AKIAUSERINTERN000001 intern/secret/0123456789abcdefgh" "AKIAUSERANALYST00001 analyst/secret/0123456789abcdefg" \
    "AKIAUSERWRITER000001 writer/secret/0123456789abcdefgh" \
    > "$work/users.credentials"
# The account's keys, named (any key the file names neither as the account's nor a user's is refused); each user:
# its name and id, its keys, its identity policy.
echo "account $AWS_ACCESS_KEY_ID" > "$work/users.file"
cat >> "$work/users.file" <<'USERS'
reader:AIDAREADER0001 AKIAUSERREADER000001 {"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::team","arn:aws:s3:::team/*"]}}
intern:AIDAINTERN0001 AKIAUSERINTERN000001 {"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:*","Resource":["arn:aws:s3:::team","arn:aws:s3:::team/*"]}}
writer:AIDAWRITER0001 AKIAUSERWRITER000001 {"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:*","Resource":["arn:aws:s3:::wsrc","arn:aws:s3:::wsrc/*","arn:aws:s3:::wdst","arn:aws:s3:::wdst/*"]}}
analyst:AIDAANALYST001 AKIAUSERANALYST00001 {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3tables:Get*","s3tables:List*"],"Resource":["arn:aws:s3tables:*:*:bucket/lake","arn:aws:s3tables:*:*:bucket/lake/table/*"]},{"Effect":"Allow","Action":"sts:AssumeRole","Resource":"arn:aws:iam::000000000000:role/tablereader"}]}
USERS
cat > "$work/users.roles" <<'ROLES'
tablereader 3600 {"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["s3tables:Get*","s3tables:List*"],"Resource":"*"}}
ROLES
"$bin" serve "$work/users-store" "$usersport" "$work/users.credentials" localhost --users-file "$work/users.file" --maintain-seconds 2 --access-log-seconds 2 --inventory-day-seconds 3 --sts-key-file "$work/sts.keys" --roles-file "$work/users.roles" 2>> "$work/users.log" &
usersrv=$!
sleep 1
ua() { AWS_ENDPOINT_URL="http://127.0.0.1:$usersport" aws "$@"; }
ur() { AWS_ENDPOINT_URL="http://127.0.0.1:$usersport" AWS_ACCESS_KEY_ID=AKIAUSERREADER000001 AWS_SECRET_ACCESS_KEY=reader/secret/0123456789abcdefgh aws "$@"; }
ui() { AWS_ENDPOINT_URL="http://127.0.0.1:$usersport" AWS_ACCESS_KEY_ID=AKIAUSERINTERN000001 AWS_SECRET_ACCESS_KEY=intern/secret/0123456789abcdefgh aws "$@"; }
ucode() { "$@" 2>&1 | sed -n 's/.*error occurred (\([A-Za-z0-9]*\)).*/\1/p' | head -1; }
ua s3api create-bucket --bucket team > /dev/null 2>&1
ua s3api create-bucket --bucket other > /dev/null 2>&1
ua s3api put-object --bucket team --key a.txt --body dir.txt > /dev/null 2>&1
ua s3api put-object --bucket other --key b.txt --body dir.txt > /dev/null 2>&1
ur s3api get-object --bucket team --key a.txt users.out > /dev/null 2>&1 && pass "a user reads what its policy allows" || fail "a user reads what its policy allows"
check "not another bucket" "$(ucode ur s3api get-object --bucket other --key b.txt users.out)" AccessDenied
check "nor writes" "$(ucode ur s3api put-object --bucket team --key c.txt --body dir.txt)" AccessDenied
check "nor lists every bucket" "$(ucode ur s3api list-buckets)" AccessDenied
check "nor makes a bucket" "$(ucode ur s3api create-bucket --bucket mine)" AccessDenied
check "nor reads the bucket's policy" "$(ucode ur s3api get-bucket-policy --bucket team)" AccessDenied
# The bucket's policy names users: its Allow lets the reader write an inbox; its Deny refuses the intern's deletes.
ua s3api put-bucket-policy --bucket team --policy '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::000000000000:user/reader"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::team/inbox/*"},{"Effect":"Deny","Principal":{"AWS":"arn:aws:iam::000000000000:user/intern"},"Action":"s3:DeleteObject","Resource":"arn:aws:s3:::team/*"}]}' > /dev/null 2>&1
ur s3api put-object --bucket team --key inbox/x.txt --body dir.txt > /dev/null 2>&1 && pass "the bucket's Allow lets a user write" || fail "the bucket's Allow lets a user write"
check "the bucket's Deny wins over the user's Allow" "$(ucode ui s3api delete-object --bucket team --key a.txt)" AccessDenied
ui s3api put-object --bucket team --key i.txt --body dir.txt > /dev/null 2>&1 && pass "the user's Allow does the rest" || fail "the user's Allow does the rest"
check "the account's key is not narrowed" "$(ua s3api list-buckets --query 'length(Buckets)')" 2
# The M11 exit review's A4 and A1: a write's ACL is a call of its own, and a user replicates only where it may write.
check "an ACL on a write needs PutObjectAcl" "$(ucode ur s3api put-object --bucket team --key inbox/y.txt --body dir.txt --acl public-read)" AccessDenied
ua s3api put-bucket-versioning --bucket other --versioning-configuration Status=Enabled > /dev/null 2>&1
ui s3api put-bucket-versioning --bucket team --versioning-configuration Status=Enabled > /dev/null 2>&1
check "a user replicates into no bucket it may not write" "$(ucode ui s3api put-bucket-replication --bucket team --replication-configuration '{"Role":"arn:aws:iam::000000000000:role/r","Rules":[{"Status":"Enabled","Priority":1,"Filter":{},"DeleteMarkerReplication":{"Status":"Disabled"},"Destination":{"Bucket":"arn:aws:s3:::other"}}]}')" AccessDenied
check "nor logs into one" "$(ucode ui s3api put-bucket-logging --bucket team --bucket-logging-status '{"LoggingEnabled":{"TargetBucket":"other","TargetPrefix":"logs/"}}')" AccessDenied
# Configurations decided at delivery (ADR-0094): the writer's replication and logs go while its policy allows them,
# and stop at the next write once it is narrowed, though the configurations stay.
uw() { AWS_ENDPOINT_URL="http://127.0.0.1:$usersport" AWS_ACCESS_KEY_ID=AKIAUSERWRITER000001 AWS_SECRET_ACCESS_KEY=writer/secret/0123456789abcdefgh aws "$@"; }
for b in wsrc wdst; do ua s3api create-bucket --bucket $b > /dev/null 2>&1; ua s3api put-bucket-versioning --bucket $b --versioning-configuration Status=Enabled > /dev/null 2>&1; done
uw s3api put-bucket-replication --bucket wsrc --replication-configuration '{"Role":"arn:aws:iam::000000000000:role/r","Rules":[{"ID":"w","Status":"Enabled","Priority":1,"Filter":{},"DeleteMarkerReplication":{"Status":"Disabled"},"Destination":{"Bucket":"arn:aws:s3:::wdst"}}]}' > /dev/null 2>&1 && pass "a user's replication put" || fail "a user's replication put"
uw s3api put-bucket-logging --bucket wsrc --bucket-logging-status '{"LoggingEnabled":{"TargetBucket":"wdst","TargetPrefix":"logs/"}}' > /dev/null 2>&1 && pass "and its logging" || fail "and its logging"
uw s3api put-object --bucket wsrc --key one.txt --body dir.txt > /dev/null 2>&1
wstatus() { ua s3api head-object --bucket wsrc --key "$1" --query ReplicationStatus --output text 2>/dev/null; }
for i in $(seq 1 40); do [ "$(wstatus one.txt)" = COMPLETED ] && break; sleep 0.25; done
check "replicated while its policy allows it" "$(wstatus one.txt)" COMPLETED
# An inventory report is decided file by file (the M14 exit review's A1): a Deny on its dated keys keeps its manifest
# out, though its policy allows the rest.
uw s3api put-bucket-inventory-configuration --bucket wsrc --id i1 --inventory-configuration '{"Id":"i1","IsEnabled":true,"Destination":{"S3BucketDestination":{"Bucket":"arn:aws:s3:::wdst","Format":"CSV","Prefix":"inv"}},"Schedule":{"Frequency":"Daily"},"IncludedObjectVersions":"Current"}' > /dev/null 2>&1 && pass "a user's inventory put" || fail "a user's inventory put"
ua s3api put-bucket-policy --bucket wdst --policy '{"Version":"2012-10-17","Statement":{"Effect":"Deny","Principal":{"AWS":"arn:aws:iam::000000000000:user/writer"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::wdst/inv/wsrc/i1/2*"}}' > /dev/null 2>&1
# A first report may be written before the Deny is in: none after it, over several of the test's days.
manifests() { ua s3api list-objects-v2 --bucket wdst --prefix inv/ --query 'length(Contents[?ends_with(Key, `manifest.json`)] || `[]`)' --output text 2>&1; }
before=$(manifests)
sleep 10
check "no manifest past a Deny on its keys" "$(manifests)" "$before"
ua s3api delete-bucket-policy --bucket wdst > /dev/null 2>&1
sed -i.bak 's#"arn:aws:s3:::wsrc","arn:aws:s3:::wsrc/\*","arn:aws:s3:::wdst","arn:aws:s3:::wdst/\*"#"arn:aws:s3:::wsrc","arn:aws:s3:::wsrc/*"#' "$work/users.file"
sleep 4
uw s3api put-object --bucket wsrc --key two.txt --body dir.txt > /dev/null 2>&1
for i in $(seq 1 40); do [ "$(wstatus two.txt)" = FAILED ] && break; sleep 0.25; done
check "its policy narrowed, the next replica is refused as its requester (FAILED)" "$(wstatus two.txt)" FAILED
for i in $(seq 1 30); do grep -q "an access log was refused as its configuration's requester" "$work/users.log" && break; sleep 0.5; done
grep -q "an access log was refused as its configuration's requester" "$work/users.log" && pass "and its log objects are refused" || fail "and its log objects are refused"
# The users file is reloaded with the credentials: the reader may now read the other bucket too.
sed -i.bak 's#"arn:aws:s3:::team/\*"\]}}$#"arn:aws:s3:::team/*","arn:aws:s3:::other/*"]}}#' "$work/users.file"
sleep 4
ur s3api get-object --bucket other --key b.txt users.out > /dev/null 2>&1 && pass "a users file reloaded" || fail "a users file reloaded"
# Two reloads: the writer's policy narrowed (ADR-0094's checks, above), then this one.
check "its reload in the log" "$(grep -c 'credentials reloaded' "$work/users.log")" 2
# S3 Tables and STS for users (ADR-0088 §2, §4): the analyst reads table bucket `lake` and its data, nothing else.
uan() { AWS_ENDPOINT_URL="http://127.0.0.1:$usersport" AWS_ACCESS_KEY_ID=AKIAUSERANALYST00001 AWS_SECRET_ACCESS_KEY=analyst/secret/0123456789abcdefg aws "$@"; }
lake=$(ua s3tables create-table-bucket --name lake --query arn --output text 2>&1)
ua s3tables create-namespace --table-bucket-arn "$lake" --namespace ns > /dev/null 2>&1
ua s3tables create-table --table-bucket-arn "$lake" --namespace ns --name t --format ICEBERG > /dev/null 2>&1
lwh=$(ua s3tables get-table --table-bucket-arn "$lake" --namespace ns --name t --query warehouseLocation --output text 2>&1)
lb=${lwh#s3://}; lb=${lb%%/*}; lp=${lwh#s3://*/}
ua s3api put-object --bucket "$lb" --key "$lp/data/a.parquet" --body dir.txt > /dev/null 2>&1
check "a user reads a table its policy allows" "$(uan s3tables get-table --table-bucket-arn "$lake" --namespace ns --name t --query name --output text 2>&1)" t
check "and its data" "$(uan s3api get-object --bucket "$lb" --key "$lp/data/a.parquet" users.out > /dev/null 2>&1 && echo read)" read
check "not writing its data" "$(ucode uan s3api put-object --bucket "$lb" --key "$lp/data/b.parquet" --body dir.txt)" AccessDenied
check "nor dropping it" "$(ucode uan s3tables delete-table --table-bucket-arn "$lake" --namespace ns --name t)" ForbiddenException
check "nor listing every table bucket" "$(ucode uan s3tables list-table-buckets)" ForbiddenException
# A role it may assume; its session reads tables and drops none. Another user may not assume it.
rcreds=$(uan sts assume-role --role-arn arn:aws:iam::000000000000:role/tablereader --role-session-name smoke-session --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1)
read -r rak rsk rst <<< "$rcreds"
urole() { AWS_ENDPOINT_URL="http://127.0.0.1:$usersport" AWS_ACCESS_KEY_ID="$rak" AWS_SECRET_ACCESS_KEY="$rsk" AWS_SESSION_TOKEN="$rst" aws "$@"; }
check "a role's session reads a table" "$(urole s3tables get-table --table-bucket-arn "$lake" --namespace ns --name t --query name --output text 2>&1)" t
check "and drops none" "$(ucode urole s3tables delete-table --table-bucket-arn "$lake" --namespace ns --name t)" ForbiddenException
check "a user its policy does not let assume it" "$(ucode ui sts assume-role --role-arn arn:aws:iam::000000000000:role/tablereader --role-session-name smoke-session)" AccessDenied
# The roles file reloaded (ADR-0096 §1): the role removed, its session's next request is refused, no restart.
cp "$work/users.roles" "$work/users.roles.kept"
: > "$work/users.roles"
sleep 4
# Through S3, whose error names its code (S3 Tables answers it as a bare 400).
check "a role removed refuses its session, without a restart" "$(ucode urole s3api list-objects-v2 --bucket team)" InvalidToken
grep -q "roles reloaded" "$work/users.log" && pass "the roles reload logged" || fail "the roles reload logged"
cp "$work/users.roles.kept" "$work/users.roles"
sleep 4 # the roles back before the checks after (the M15 exit review)
check "nor probe a table bucket's warehouse" "$(ucode ui s3api head-bucket --bucket "$lb")" 403
# The M11 exit review's A2: a user's line removed, its key is refused, not the account's.
sed -i.bak '/^intern:/d' "$work/users.file"
sleep 4
check "a removed user's key is refused" "$(ucode ui s3api list-buckets)" InvalidAccessKeyId
# A user made again with its name has a new id, and not the old one's grants (the bucket's Allow of reader's inbox).
sed -i.bak 's/^reader:AIDAREADER0001 /reader:AIDAREADER0002 /' "$work/users.file"
sleep 4
check "a user made again has not the old one's grants" "$(ucode ur s3api put-object --bucket team --key inbox/z.txt --body dir.txt)" AccessDenied
kill "$usersrv" 2>/dev/null

# Storage classes (ADR-0090 §1): recorded on the object and answered, or refused; never dropped.
aws s3api create-bucket --bucket classes > /dev/null 2>&1
aws s3api put-object --bucket classes --key ia --body dir.txt --storage-class STANDARD_IA > /dev/null 2>&1
check "a storage class recorded" "$(aws s3api head-object --bucket classes --key ia --query StorageClass --output text 2>&1)" STANDARD_IA
check "and listed" "$(aws s3api list-objects-v2 --bucket classes --query 'Contents[0].StorageClass' --output text 2>&1)" STANDARD_IA
check "and in its versions" "$(aws s3api list-object-versions --bucket classes --query 'Versions[0].StorageClass' --output text 2>&1)" STANDARD_IA
aws s3api put-object --bucket classes --key std --body dir.txt --storage-class STANDARD > /dev/null 2>&1
check "STANDARD is not named on the object" "$(aws s3api head-object --bucket classes --key std --query StorageClass --output text 2>&1)" None
# The archive classes (ADR-0102): taken; their reads, and copies from them, InvalidObjectState until restored.
check "an archive class taken" "$(aws s3api put-object --bucket classes --key g --body dir.txt --storage-class GLACIER --query ETag --output text 2>&1 | tr -d '"' | wc -c | tr -d ' ')" 33
check "and named on the object" "$(aws s3api head-object --bucket classes --key g --query StorageClass --output text 2>&1)" GLACIER
check "its read refused, not restored" "$(code s3api get-object --bucket classes --key g "$work/g.out")" InvalidObjectState
check "a copy from it refused" "$(code s3api copy-object --bucket classes --key g2 --copy-source classes/g)" InvalidObjectState
aws s3api put-object --bucket classes --key deep --body dir.txt --storage-class DEEP_ARCHIVE > /dev/null 2>&1
check "DEEP_ARCHIVE too" "$(code s3api get-object --bucket classes --key deep "$work/g.out")" InvalidObjectState
# Refused before its conditions and range, as S3 does (ADR-0106 §1.4): no 304, 412 or 416 tells of it.
getag=$(aws s3api head-object --bucket classes --key g --query ETag --output text 2>&1)
check "a matching If-None-Match refused, not 304" "$(code s3api get-object --bucket classes --key g --if-none-match "$getag" "$work/g.out")" InvalidObjectState
check "a failing If-Match refused, not 412" "$(code s3api get-object --bucket classes --key g --if-match '"0"' "$work/g.out")" InvalidObjectState
check "a range past its end refused, not 416" "$(code s3api get-object --bucket classes --key g --range bytes=999999-1000000 "$work/g.out")" InvalidObjectState
check "while HEAD still takes its conditions" "$(code s3api head-object --bucket classes --key g --if-none-match "$getag")" 304
check "and an unknown class refused" "$(code s3api put-object --bucket classes --key g --body dir.txt --storage-class SHELF)" InvalidStorageClass
# RestoreObject (ADR-0102 §5): an hour is a second here (--restore-hour-seconds 1), so Standard's 4 hours take 4 s, and
# a day 24 s.
restore() { aws s3api restore-object --bucket classes --key "$1" --restore-request "$2" 2>&1; }
# Bulk: 8 hours, 8 s here, so the checks of a restore that runs hold on a loaded machine (Standard's 4 s did not).
check "a restore started" "$(restore g '{"Days":1,"GlacierJobParameters":{"Tier":"Bulk"}}' | grep -c . )" 0
check "restoring" "$(aws s3api head-object --bucket classes --key g --query Restore --output text 2>&1)" 'ongoing-request="true"'
check "its read refused while restoring" "$(code s3api get-object --bucket classes --key g "$work/g.out")" InvalidObjectState
check "a listing's RestoreStatus while restoring" "$(aws s3api list-objects-v2 --bucket classes --optional-object-attributes RestoreStatus --query "Contents[?Key=='g'].RestoreStatus.IsRestoreInProgress" --output text 2>&1)" True
check "a restore while one runs" "$(code s3api restore-object --bucket classes --key g --restore-request '{"Days":1}')" RestoreAlreadyInProgress
for i in $(seq 1 60); do aws s3api head-object --bucket classes --key g --query Restore --output text 2>&1 | grep -q 'ongoing-request="false"' && break; sleep 0.5; done
check "restored: its expiry shown" "$(aws s3api head-object --bucket classes --key g --query Restore --output text 2>&1 | sed 's/expiry-date=".*"/expiry-date=…/')" 'ongoing-request="false", expiry-date=…'
check "and in a listing, with its expiry" "$(aws s3api list-objects-v2 --bucket classes --optional-object-attributes RestoreStatus --query "Contents[?Key=='g'].[RestoreStatus.IsRestoreInProgress, RestoreStatus.RestoreExpiryDate != null]" --output text 2>&1 | tr '\t' ' ')" "False True"
check "a key never restored has none" "$(aws s3api list-objects-v2 --bucket classes --optional-object-attributes RestoreStatus --query "Contents[?Key=='deep'].RestoreStatus" --output text 2>&1)" ""
check "and it reads" "$(aws s3api get-object --bucket classes --key g "$work/g.out" > /dev/null 2>&1 && cmp -s dir.txt "$work/g.out" && echo same)" same
check "a restore of a restored version extends it" "$(restore g '{"Days":2}' | grep -c .)" 0
# A copy of a restored version is not restored (the M18 exit review): archived, it is restored on its own.
aws s3api copy-object --bucket classes --key g-copy --copy-source classes/g --storage-class GLACIER > /dev/null 2>&1
check "a copy of a restored version, archived, is not restored" "$(code s3api get-object --bucket classes --key g-copy "$work/g.out")" InvalidObjectState
check "nor says it is" "$(aws s3api head-object --bucket classes --key g-copy --query Restore --output text 2>&1)" None
check "Expedited is not for DEEP_ARCHIVE" "$(code s3api restore-object --bucket classes --key deep --restore-request '{"Days":1,"GlacierJobParameters":{"Tier":"Expedited"}}')" InvalidArgument
aws s3api put-object --bucket classes --key warm --body dir.txt > /dev/null 2>&1
check "a version not archived is not restored" "$(code s3api restore-object --bucket classes --key warm --restore-request '{"Days":1}')" InvalidObjectState
check "a tier not known" "$(code s3api restore-object --bucket classes --key deep --restore-request '{"Days":1,"GlacierJobParameters":{"Tier":"Slow"}}')" MalformedXML
check "a bucket that is not there, before the class (M12 review)" "$(code s3api put-object --bucket no-such-classes --key g --body dir.txt --storage-class GLACIER)" NoSuchBucket
aws s3api copy-object --bucket classes --key ia --copy-source classes/ia --storage-class ONEZONE_IA > /dev/null 2>&1
check "a copy onto itself changes only its class" "$(aws s3api head-object --bucket classes --key ia --query StorageClass --output text 2>&1)" ONEZONE_IA
aws s3api copy-object --bucket classes --key copied --copy-source classes/ia > /dev/null 2>&1
check "a copy onto itself of the class it has refused (M12 review B4)" "$(code s3api copy-object --bucket classes --key ia --copy-source classes/ia --storage-class ONEZONE_IA)" InvalidRequest
check "a copy takes the request's class, not the source's" "$(aws s3api head-object --bucket classes --key copied --query StorageClass --output text 2>&1)" None
up=$(aws s3api create-multipart-upload --bucket classes --key mp --storage-class GLACIER_IR --query UploadId --output text 2>&1)
check "an upload's class listed" "$(aws s3api list-multipart-uploads --bucket classes --query 'Uploads[0].StorageClass' --output text 2>&1)" GLACIER_IR
aws s3api abort-multipart-upload --bucket classes --key mp --upload-id "$up" > /dev/null 2>&1
for k in ia std copied g deep warm g-copy; do aws s3api delete-object --bucket classes --key "$k" > /dev/null 2>&1; done
# Lifecycle transitions (ADR-0090 §2): taken to the classes kept here, the archive ones too (ADR-0102).
aws s3api put-bucket-lifecycle-configuration --bucket classes --lifecycle-configuration '{"Rules":[{"ID":"tiers","Status":"Enabled","Filter":{"Prefix":"logs/"},"Transitions":[{"Days":30,"StorageClass":"STANDARD_IA"},{"Days":90,"StorageClass":"GLACIER_IR"}],"NoncurrentVersionTransitions":[{"NoncurrentDays":30,"StorageClass":"ONEZONE_IA","NewerNoncurrentVersions":2}]}]}' > /dev/null 2>&1 && pass "lifecycle transitions taken" || fail "lifecycle transitions taken"
check "and returned" "$(aws s3api get-bucket-lifecycle-configuration --bucket classes --query 'Rules[0].[Transitions[1].StorageClass,NoncurrentVersionTransitions[0].NewerNoncurrentVersions]' --output text 2>&1)" "GLACIER_IR	2"
aws s3api put-bucket-lifecycle-configuration --bucket classes --lifecycle-configuration '{"Rules":[{"ID":"g","Status":"Enabled","Filter":{"Prefix":"archive/"},"Transitions":[{"Days":30,"StorageClass":"GLACIER"},{"Days":180,"StorageClass":"DEEP_ARCHIVE"}]}]}' > /dev/null 2>&1 && pass "transitions to the archive classes taken" || fail "transitions to the archive classes taken"
check "and to infrequent access before 30 days" "$(code s3api put-bucket-lifecycle-configuration --bucket classes --lifecycle-configuration '{"Rules":[{"ID":"i","Status":"Enabled","Filter":{},"Transitions":[{"Days":7,"StorageClass":"STANDARD_IA"}]}]}')" InvalidArgument
check "the bucket's transition minimum answered" "$(aws s3api get-bucket-lifecycle-configuration --bucket classes --query TransitionDefaultMinimumObjectSize --output text 2>&1)" varies_by_storage_class
check "a transition minimum S3 has not refused" "$(code s3api put-bucket-lifecycle-configuration --bucket classes --transition-default-minimum-object-size bogus --lifecycle-configuration '{"Rules":[{"ID":"tiers","Status":"Enabled","Filter":{},"Transitions":[{"Days":30,"StorageClass":"STANDARD_IA"}]}]}')" InvalidArgument
aws s3api put-bucket-lifecycle-configuration --bucket classes --transition-default-minimum-object-size all_storage_classes_128K --lifecycle-configuration '{"Rules":[{"ID":"tiers","Status":"Enabled","Filter":{},"Transitions":[{"Days":30,"StorageClass":"STANDARD_IA"}]}]}' > /dev/null 2>&1
check "and its other value kept" "$(aws s3api get-bucket-lifecycle-configuration --bucket classes --query TransitionDefaultMinimumObjectSize --output text 2>&1)" all_storage_classes_128K
check "REDUCED_REDUNDANCY is no transition's (M12 review B1)" "$(code s3api put-bucket-lifecycle-configuration --bucket classes --lifecycle-configuration '{"Rules":[{"ID":"r","Status":"Enabled","Filter":{},"Transitions":[{"Days":30,"StorageClass":"REDUCED_REDUNDANCY"}]}]}')" InvalidStorageClass
check "transitions out of the waterfall's order refused (B2)" "$(code s3api put-bucket-lifecycle-configuration --bucket classes --lifecycle-configuration '{"Rules":[{"ID":"o","Status":"Enabled","Filter":{},"Transitions":[{"Days":30,"StorageClass":"GLACIER_IR"},{"Days":60,"StorageClass":"STANDARD_IA"}]}]}')" InvalidArgument
check "and an expiration before a transition" "$(code s3api put-bucket-lifecycle-configuration --bucket classes --lifecycle-configuration '{"Rules":[{"ID":"e","Status":"Enabled","Filter":{},"Expiration":{"Days":10},"Transitions":[{"Days":30,"StorageClass":"STANDARD_IA"}]}]}')" InvalidArgument
aws s3api delete-bucket-lifecycle --bucket classes > /dev/null 2>&1
# ListMultipartUploads' delimiter (ADR-0090 §3) and SHA-1 checksums (§4).
u1=$(aws s3api create-multipart-upload --bucket classes --key logs/a --query UploadId --output text 2>&1)
u2=$(aws s3api create-multipart-upload --bucket classes --key logs/b --query UploadId --output text 2>&1)
u3=$(aws s3api create-multipart-upload --bucket classes --key top --query UploadId --output text 2>&1)
check "uploads rolled up by a delimiter" "$(aws s3api list-multipart-uploads --bucket classes --delimiter / --query '[CommonPrefixes[0].Prefix,Uploads[0].Key,length(Uploads)]' --output text 2>&1)" "logs/	top	1"
aws s3api abort-multipart-upload --bucket classes --key logs/a --upload-id "$u1" > /dev/null 2>&1
aws s3api abort-multipart-upload --bucket classes --key logs/b --upload-id "$u2" > /dev/null 2>&1
aws s3api abort-multipart-upload --bucket classes --key top --upload-id "$u3" > /dev/null 2>&1
printf 'abc' > sha1.txt
check "a SHA-1 checksum taken" "$(aws s3api put-object --bucket classes --key sha1 --body sha1.txt --checksum-algorithm SHA1 --query ChecksumSHA1 --output text 2>&1)" "qZk+NkcGgWq6PiVxeFDCbJzQ2J0="
check "and returned" "$(aws s3api head-object --bucket classes --key sha1 --checksum-mode ENABLED --query ChecksumSHA1 --output text 2>&1)" "qZk+NkcGgWq6PiVxeFDCbJzQ2J0="
check "a wrong one refused" "$(code s3api put-object --bucket classes --key sha1 --body sha1.txt --checksum-sha1 2jmj7l5rSw0yVb/vlWAYkK/YBwk=)" BadDigest
aws s3api delete-object --bucket classes --key sha1 > /dev/null 2>&1
rm -f sha1.txt
aws s3api delete-bucket --bucket classes > /dev/null 2>&1

# Deletes free the space.
aws s3 rm --recursive s3://smoke/ > /dev/null 2>&1
aws s3api delete-bucket --bucket smoke > /dev/null 2>&1 && pass "delete-bucket" || fail "delete-bucket"
aws s3api create-bucket --bucket after > /dev/null 2>&1 # a commit, which reaps what readers held
check "no extents left" "$(ls store/extents | wc -l | tr -d ' ')" 0

kill "$server" "$hook"
wait "$server" "$hook" 2> /dev/null
"$bin" fsck store > fsck.out 2>&1 && pass "fsck" || { fail "fsck"; cat fsck.out; }
if [ -s server.log ] && grep -q "Internal\|Unavailable" server.log; then fail "server logged errors"; cat server.log; fi
[ "$failed" = 0 ] && echo "s3 smoke: all passed" || echo "s3 smoke: FAILED"
exit "$failed"
