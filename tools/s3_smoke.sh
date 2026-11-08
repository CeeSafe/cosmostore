#!/bin/sh
# The M3 end-to-end test (ADR-0008 to ADR-0017): the AWS CLI v2, and tools/s3_raw.py for what the CLI does not send,
# against `cosmostore serve` on a fresh store. Prints one line per check; exit status 1 if any fails.
#
# usage: tools/s3_smoke.sh [COSMOSTORE] [PORT]     (defaults: out/cosmostore, 9311)
set -u
bin=$(cd "$(dirname "${1:-out/cosmostore}")" && pwd)/$(basename "${1:-out/cosmostore}")
port=${2:-9311}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'kill "$server" 2>/dev/null; rm -rf "$work"' EXIT

export AWS_ACCESS_KEY_ID=AKIASMOKETEST0000001
export AWS_SECRET_ACCESS_KEY=smoke/secret/0123456789abcdefghijkl
export AWS_DEFAULT_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true
export AWS_ENDPOINT_URL="http://127.0.0.1:$port"
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > "$work/credentials"

"$bin" serve "$work/store" "$port" "$work/credentials" localhost 2> "$work/server.log" &
server=$!
sleep 1

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

# Deletes free the space.
aws s3 rm --recursive s3://smoke/ > /dev/null 2>&1
aws s3api delete-bucket --bucket smoke > /dev/null 2>&1 && pass "delete-bucket" || fail "delete-bucket"
aws s3api create-bucket --bucket after > /dev/null 2>&1 # a commit, which reaps what readers held
check "no extents left" "$(ls store/extents | wc -l | tr -d ' ')" 0

kill "$server"
wait "$server" 2> /dev/null
"$bin" fsck store > fsck.out 2>&1 && pass "fsck" || { fail "fsck"; cat fsck.out; }
if [ -s server.log ] && grep -q "Internal\|Unavailable" server.log; then fail "server logged errors"; cat server.log; fi
[ "$failed" = 0 ] && echo "s3 smoke: all passed" || echo "s3 smoke: FAILED"
exit "$failed"
