#!/usr/bin/env bash
# Shared validation for GSM / file Grafana edge JSON.

validate_grafana_edge_json() {
  local file="$1"
  jq -e '
    (.google_client_id | type == "string" and length > 0
      and (test("REPLACE|YOUR_|REPLACE_ME"; "i") | not)) and
    (.google_client_secret | type == "string" and length > 0
      and (test("REPLACE|YOUR_|REPLACE_ME"; "i") | not)) and
    (.cookie_secret | type == "string" and length >= 16
      and (test("REPLACE|YOUR_|REPLACE_ME"; "i") | not)) and
    (
      (.superadmin_emails | type == "array" and length > 0) or
      (.superadmin_emails | type == "string" and length > 0)
    )
  ' "$file" >/dev/null 2>&1
}
