{
  "name": "Volt MX Foundry app",
  "type": "scope",
  "assignable_to": "any",
  "use_default_actions": false,
  "available_actions": [
    "create-scope",
    "update-scope",
    "delete-scope",
    "start-initial",
    "rollback-deployment",
    "delete-deployment",
    "diagnose-scope"
  ],
  "visible_to": [
    "{{ env.Getenv "NRN" }}"
  ],
  "selectors": {
    "category": "Scope",
    "imported": false,
    "provider": "Agent",
    "sub_category": "Volt MX Foundry app"
  },
  "dimensions": {},
  "scopes": {},
  "attributes": {
    "schema": {
      "type": "object",
      "required": ["foundry_app_name"],
      "properties": {
        "asset_type": {
          "type": "string",
          "default": "bundle",
          "export": false,
          "description": "Asset type this scope deploys. The exported Foundry app zip is registered as a bundle asset named foundry"
        },
        "foundry_app_name": {
          "type": "string",
          "title": "Foundry app name",
          "description": "Name of the app in Foundry, exactly as it appears in the console (e.g. PetStore). Each deployment publishes the release version of this app.",
          "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]*$",
          "editableOn": ["create"]
        }
      },
      "uiSchema": {
        "type": "VerticalLayout",
        "elements": [
          { "type": "Control", "scope": "#/properties/foundry_app_name" }
        ]
      }
    },
    "values": {}
  }
}
