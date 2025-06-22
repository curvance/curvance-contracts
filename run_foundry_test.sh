#!/bin/bash
TEST_NAME="$1"
FILE_PATH="$2"
if [ -z "$TEST_NAME" ]; then
  echo "Error: No test name selected. Highlight the test function name in the editor."
  exit 1
fi
if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
  echo "Error: Invalid or missing file path."
  exit 1
fi
# Extract contract name (prefer contracts with 'Test' in name, else first contract)
CONTRACT_NAME=$(grep -o -E 'contract\s+[A-Za-z0-9_]+Test[A-Za-z0-9_]*' "$FILE_PATH" | awk '{print $2}' | head -n 1)
if [ -z "$CONTRACT_NAME" ]; then
  # Fallback: Use first contract if no 'Test' contract found
  CONTRACT_NAME=$(grep -m 1 -o -E 'contract\s+[A-Za-z0-9_]+' "$FILE_PATH" | awk '{print $2}')
fi
if [ -z "$CONTRACT_NAME" ]; then
  echo "Error: No contract name found in $FILE_PATH."
  exit 1
fi
# Run forge test
forge test --match-test "$TEST_NAME" --match-contract "$CONTRACT_NAME" --ffi -vvvv