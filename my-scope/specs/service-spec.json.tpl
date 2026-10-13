{
  "name": "My Scope",
  "type": "scope",
  "assignable_to": "any",
  "use_default_actions": false,
  "available_actions": [
    "create-scope",
    "update-scope",
    "delete-scope",
    "start-initial",
    "start-blue-green",
    "switch-traffic",
    "finalize-blue-green",
    "rollback-deployment",
    "delete-deployment"
  ],
  "visible_to": [
    "{{ env.Getenv "NRN" }}"
  ],
  "selectors": {
    "category": "Scope",
    "imported": false,
    "provider": "Agent",
    "sub_category": "My Scope"
  },
  "dimensions": {},
  "scopes": {},
  "attributes": {
    "schema": {
      "type": "object",
      "required": ["example"],
      "properties": {
        "example": {
          "type": "string",
          "title": "Example",
          "description": "Replace with the capabilities developers choose, in their words, not the cloud's",
          "default": "",
          "editableOn": ["create", "update"]
        }
      },
      "uiSchema": {
        "type": "VerticalLayout",
        "elements": [
          { "type": "Control", "scope": "#/properties/example" }
        ]
      }
    },
    "values": {}
  }
}
