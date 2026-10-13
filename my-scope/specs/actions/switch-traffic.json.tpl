{
  "name": "switch-traffic",
  "slug": "switch-traffic",
  "type": "custom",
  "retryable": true,
  "service_specification_id": "{{ env.Getenv "SERVICE_SPECIFICATION_ID" }}",
  "parameters": {
    "schema": {
      "type": "object",
      "required": ["scope_id", "deployment_id", "desired_traffic"],
      "properties": {
        "scope_id": { "type": "string" },
        "deployment_id": { "type": "string" },
        "desired_traffic": { "type": "number" }
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
  }
}
