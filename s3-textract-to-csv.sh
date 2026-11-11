#!/usr/bin/env bash

set -u
set -o pipefail

# ------------------------------------------------------------
# S3 Textract OCR to CSV
#
# Requirements:
#   - AWS CLI configured with suitable permissions
#   - jq installed
#   - Images stored in an S3 bucket
# ------------------------------------------------------------

read -rp "Enter the S3 bucket name: " BUCKET

if [[ -z "$BUCKET" ]]; then
    echo "Error: An S3 bucket name is required."
    exit 1
fi

read -rp "Enter an optional S3 prefix/folder, or press Enter for the entire bucket: " PREFIX

JSON_DIR="./textract-json"
CSV_FILE="./textract-results.csv"

mkdir -p "$JSON_DIR"

# Confirm required commands are installed.
for COMMAND in aws jq; do
    if ! command -v "$COMMAND" >/dev/null 2>&1; then
        echo "Error: '$COMMAND' is not installed or not available in PATH."
        exit 1
    fi
done

# Confirm that AWS credentials and configuration work.
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "Error: Unable to authenticate with AWS."
    echo "Run 'aws configure' or verify your AWS credentials."
    exit 1
fi

# Confirm that the bucket is accessible.
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "Error: Bucket '$BUCKET' does not exist or is not accessible."
    exit 1
fi

# Create or overwrite the CSV with a header row.
printf '%s\n' 'FileName,Subject,Location,Timestamp' > "$CSV_FILE"

PROCESSED=0
FAILED=0

echo
echo "Processing images in s3://$BUCKET/$PREFIX"
echo

# List object keys one per line.
#
# The --query filter limits the results to recognized image extensions.
# AWS CLI handles ListObjectsV2 pagination automatically unless
# --no-paginate is specified.
aws s3api list-objects-v2 \
    --bucket "$BUCKET" \
    --prefix "$PREFIX" \
    --query 'Contents[].Key' \
    --output text |
tr '\t' '\n' |
grep -Ei '\.(jpg|jpeg|png)$' |
while IFS= read -r KEY; do

    [[ -z "$KEY" ]] && continue

    echo "Processing: s3://$BUCKET/$KEY"

    BASE_NAME="$(basename "$KEY")"

    # Include a hash of the full S3 key to avoid duplicate JSON filenames
    # when different S3 folders contain files with the same basename.
    KEY_HASH="$(printf '%s' "$KEY" | sha256sum | cut -c1-12)"
    JSON_FILE="$JSON_DIR/${BASE_NAME%.*}-${KEY_HASH}.json"

    # Run synchronous Textract OCR and save the complete JSON response.
    if ! aws textract detect-document-text \
        --document "S3Object={Bucket=$BUCKET,Name=$KEY}" \
        --output json \
        > "$JSON_FILE"; then

        echo "  Error: Textract failed for '$KEY'." >&2
        rm -f "$JSON_FILE"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Extract Subject, Location, and Timestamp.
    #
    # first(...) selects the first matching LINE.
    # The // "" expression produces an empty CSV field if a value is absent.
    #
    # --arg supplies the S3 key safely to jq so that @csv can perform
    # correct CSV quoting for every column, including FileName.
    if ! jq -r --arg filename "$KEY" '
        def field($name):
            first(
                .Blocks[]?
                | select(
                    .BlockType == "LINE"
                    and (.Text? | test("^" + $name + "[[:space:]]*:"))
                )
                | .Text
                | sub(
                    "^" + $name + "[[:space:]]*:[[:space:]]*";
                    ""
                )
            ) // "";

        [
            $filename,
            field("Subject"),
            field("Location"),
            field("Timestamp")
        ]
        | @csv
    ' "$JSON_FILE" >> "$CSV_FILE"; then

        echo "  Error: Could not process Textract output for '$KEY'." >&2
        FAILED=$((FAILED + 1))
        continue
    fi

    PROCESSED=$((PROCESSED + 1))
done

echo
echo "Processing complete."
echo "CSV output:  $CSV_FILE"
echo "JSON output: $JSON_DIR"
