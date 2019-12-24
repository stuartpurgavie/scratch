# See Mount Points
path "sys/mounts*" {
  capabilities = ["read"]
}

# List existing secret engines
path "sys/mounts" {
  capabilities = ["read"]
}

# entity_cleanup Script must be able to create child Tokens, but these tokens will never have permissions outside this policy
path "auth/token/create" {
  capabilities = ["create", "read", "update", "list"]
}

# entity_cleanup Script should be able to create and modify entities for us
path "identity/entity/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "identity/entity-alias/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# entity_cleanup Script must be able to get the approle list
path "auth/approle/role" {
  capabilities = ["list"]
}

# entity_cleanup Script must be able to read the approle role ids
path "auth/approle/role/+/role-id" {
  capabilities = ["read"]
}

# entity_cleanup Script must be able to check the auth mounts
path "sys/auth" {
  capabilities = ["read", "list"]
}
