{
  "nrn": "{{ env.Getenv "NRN" }}",
  "status": "active",
  "description": "Channel to handle VoltMX Foundry app scopes",
  "type": "agent",
  "source": [
    "telemetry",
    "service"
  ],
  "configuration": {
    "api_key": "{{ env.Getenv "NP_API_KEY" }}",
    "command": {
      "type": "exec",
      "data": {
        "cmdline": "{{ env.Getenv "REPO_PATH" }}/entrypoint --service-path={{ env.Getenv "REPO_PATH" }}/{{ env.Getenv "SERVICE_PATH" }}",
        "environment": {
          "NP_ACTION_CONTEXT": "'${NOTIFICATION_CONTEXT}'"
        }
      }
    },
    "selector": {
      "environment": "{{ env.Getenv "ENVIRONMENT" }}"
    }
  },
  "filters": {
    "$or": [
      {
        "service.specification.slug": "{{ env.Getenv "SERVICE_SLUG" }}"
      },
      {
        "arguments.scope_provider": "{{ env.Getenv "SERVICE_SPECIFICATION_ID" }}"
      }
    ]
  }
}
