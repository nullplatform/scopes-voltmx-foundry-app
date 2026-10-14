{
  "name": "Diagnose Scope",
  "slug": "diagnose-scope",
  "type": "diagnose",
  "retryable": true,
  "service_specification_id": "{{ env.Getenv "SERVICE_SPECIFICATION_ID" }}",
  "parameters": {
    "schema": {
      "type": "object",
      "required": ["scope_id"],
      "properties": {
        "scope_id": {
          "type": "number",
          "readOnly": true,
          "visibleOn": ["read"]
        }
      }
    },
    "values": {}
  },
  "results": {
    "schema": {
      "type": "object",
      "required": [],
      "properties": {}
    },
    "values": {}
  },
  "annotations": {
    "show_on": ["manage", "performance"],
    "runs_over": "scope"
  }
}
