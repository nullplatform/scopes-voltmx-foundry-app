{
  "name": "Volt MX Foundry app",
  "description": "Configuration for Volt MX Foundry app scopes: the Foundry environment the apps of a namespace or dimension are published to, how the agent reaches Foundry (cloud account or on-premises URLs), which Foundry apps and which technical user its scopes may use (environments are shared by many teams), and the bucket where the CI uploads the exported apps.",
  "category": "scope-configurations",
  "icon": "mdi:server-network",
  "visible_to": [
    "{{ env.Getenv "NRN" }}"
  ],
  "allow_dimensions": true,
  "schema": {
    "type": "object",
    "required": [
      "environment_name",
      "auth",
      "credentials_secret",
      "assets"
    ],
    "anyOf": [
      {
        "required": ["allowed_apps"],
        "properties": { "allowed_apps": { "minItems": 1 } }
      },
      {
        "required": ["app_name_prefix"],
        "properties": { "app_name_prefix": { "minLength": 1 } }
      }
    ],
    "properties": {
      "environment_name": {
        "type": "string",
        "title": "Foundry environment",
        "description": "Name of the Foundry environment the apps are published to, exactly as it appears in the console (e.g. uat).",
        "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]*$"
      },
      "auth": {
        "type": "object",
        "title": "Foundry access",
        "description": "Volt MX cloud account, or the Identity and Console URLs of an on-premises Foundry.",
        "oneOf": [
          {
            "title": "Volt MX cloud",
            "type": "object",
            "required": ["account_id"],
            "additionalProperties": false,
            "properties": {
              "account_id": {
                "type": "string",
                "title": "Cloud account ID",
                "description": "9-digit Volt MX cloud account id.",
                "pattern": "^[0-9]{9}$"
              }
            }
          },
          {
            "title": "On-premises",
            "type": "object",
            "required": ["identity_url", "console_url"],
            "additionalProperties": false,
            "properties": {
              "identity_url": {
                "type": "string",
                "title": "Identity Services URL",
                "description": "https URL of the Identity Services of the Foundry server.",
                "pattern": "^https://"
              },
              "console_url": {
                "type": "string",
                "title": "Console URL",
                "description": "https URL of the Foundry console.",
                "pattern": "^https://"
              }
            }
          }
        ]
      },
      "credentials_secret": {
        "type": "string",
        "title": "Credentials secret",
        "description": "Name of the secret in the secrets manager with the Foundry technical user, as {\"username\": ..., \"password\": ...}. It must live under voltmx/<namespace slug>/ or secrets_prefix (e.g. voltmx/payments/foundry-uat).",
        "pattern": "^voltmx/[A-Za-z0-9/_-]+$"
      },
      "allowed_apps": {
        "type": "array",
        "title": "Allowed Foundry apps",
        "description": "Foundry apps the scopes of this namespace or dimension may deploy: exact names (PetStore) or a prefix followed by * (Payments*). Foundry environments are shared by many teams, so a scope can only touch the apps listed here. Set this or app_name_prefix.",
        "default": [],
        "items": {
          "type": "string",
          "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]*[*]?$"
        }
      },
      "app_name_prefix": {
        "type": "string",
        "title": "App name prefix",
        "description": "When set, every Foundry app deployed from this namespace or dimension must start with it (e.g. Payments). When allowed_apps is also set, both must match.",
        "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]*$"
      },
      "secrets_prefix": {
        "type": "string",
        "title": "Secrets prefix",
        "description": "Folder that credentials_secret must live in. Defaults to voltmx/<namespace slug>/, so a scope cannot use the Foundry technical user of another team.",
        "pattern": "^voltmx/[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*/$"
      },
      "assets": {
        "type": "object",
        "title": "Assets",
        "description": "Bucket where the CI uploads the exported Foundry apps that the scope publishes.",
        "required": ["bucket"],
        "properties": {
          "bucket": {
            "type": "string",
            "title": "Bucket",
            "description": "Name of the bucket that stores the build assets (e.g. assets-aws-mobile).",
            "pattern": "^[a-z0-9.-]+$"
          },
          "region": {
            "type": "string",
            "title": "Region",
            "description": "Region of the assets bucket and of the credentials secret.",
            "default": "us-east-1"
          }
        }
      }
    },
    "uiSchema": {
      "type": "VerticalLayout",
      "elements": [
        {
          "type": "Categorization",
          "elements": [
            {
              "type": "Category",
              "label": "Foundry",
              "elements": [
                { "type": "Control", "scope": "#/properties/environment_name" },
                { "type": "Control", "scope": "#/properties/auth" },
                { "type": "Control", "scope": "#/properties/credentials_secret" }
              ]
            },
            {
              "type": "Category",
              "label": "Apps and secrets of this namespace",
              "elements": [
                { "type": "Control", "scope": "#/properties/allowed_apps" },
                { "type": "Control", "scope": "#/properties/app_name_prefix" },
                { "type": "Control", "scope": "#/properties/secrets_prefix" }
              ]
            },
            {
              "type": "Category",
              "label": "Assets",
              "elements": [
                { "type": "Control", "scope": "#/properties/assets/properties/bucket" },
                { "type": "Control", "scope": "#/properties/assets/properties/region" }
              ]
            }
          ]
        }
      ]
    }
  }
}
