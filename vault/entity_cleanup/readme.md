# Entity Cleanup Script

This is just a quick script that I wrote in bash that loops through all entity entries in the connected Hashicorp Vault instance and does some renaming and relinking. Makes a bunch of assumptions and is a bit of a hack. Could definitely use improvement.

The purpose of this script is primarily to make entity names predictable in some way. Most of Hashicorp Vault is completely predictable, but the identity system is not completely there.

IMPORTANT: This is part of a scratch repo and makes no claims of fitness of purpose, warrantability or any of that other legal mumbo jumbo. I can't even promise it will work consistently. If you choose to use it, that's on you. I might leave master in a broken state on purpose. That's just how I roll.

## Requirements

- the Vault binary (tested with v1.3.0, latest should be fine)
- the jq binary (the bash script needs to do some json response parsing)
- environment variables set
  - especially VAULT_ADDR should be set correctly
  - script makes an effort to find a token in the current user's home directory when run interactively, but you really should use VAULT_TOKEN
- bash v3.x+
- a connection to a Vault instance
- single domain usage (multi-domain is not supported)
- auth mount types used in instance are supported (ldap, okta, userpass, aws, azure, token, approle)
- all auth methods mounted at default paths

## TODOs

I'm personally annoyed by all the AWS entities floating around in a production setting and yearn to delete the ones that aren't being used anymore. However, I just haven't gotten around to actually testing my logical conclusion that deleting the damn things will have zero impact on the system. I suspect there will be zero impact because the instance would just re-use the auth method and create a new entity in the process. If the auth method has `disallow_reauthentication = true` set, then the process should have already gotten all the secrets it needs anyway. Then hopefully used those secrets to establish an AppRole auth method. But I just haven't come up with a set of tests to make sure this functions the way I suspect. So it's disabled in the script.

## Other Notes

If you're not running a quick run, or running for the first time, this thing can take a while in a production environment. It's definitely not efficient.

I've included a sample HCL policy that would be required to run this thing. It's in `entity_cleanup_policy.hcl` for those curious.

## Usage

If you're actually crazy enough to run this thing, here's how it would go:

```bash
# One-time configuration - add your comma-separated policy list between the double quotes
sed -i -e 's/^declare defpolicy=.*$/declare defpolicy=""/' ./entity_cleanup.sh
# These will vary wildly based on your instance
export VAULT_ADDR="https://vault.example.com"
vault login # -method=authmethod etc...
# Make the script executable and...
chmod 755 entity_cleanup.sh
# ...hold onto your butts
./entity_cleanup.sh -v -f example.com
```

For best results, only use the full run occasionally and for the most part, use the `-q` flag and run every 15 minutes or so. There is also the `-d` option for if you want to add something new and test it out properly. Could use a BATS buddy script but I'm lazy.

## Conclusion

I realize that this isn't a great readme but just wanted to put this script up as an example to reference. I'm sure someone somewhere has done it better. For example, rewriting this in golang would net some serious performance gains. Maybe that should be listed in my TODOs section...
