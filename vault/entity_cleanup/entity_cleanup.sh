#!/usr/bin/env bash
# Entity Lookup Script
# Please check git log for version details
# github.com/stuartpurgavie

set -o errexit
set -o pipefail
set -o nounset
# set -o xtrace

# Set magic variables for current file & dir
__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__file="${__dir}/$(basename "${BASH_SOURCE[0]}")"
__base="$(basename ${__file} .sh)"

# Functions (if any)
function usage() {
    echo "Usage: ./${__base}.sh [-d] [-q] [-vvv] [ -f example.com ]"
    exit 2
}
# Verbosity Level for testing/manual runs
declare -i v=0
# Dry-Run functionality - all write operations are skipped
declare -i d=0
# Quick-run functionality - gets much smaller entity list of things that have never been parsed before
declare -i q=0
# Default Entity Policies to attach, comma separated array 
#  (Hashicorp reserves the right to modify the out-of-the-box default policy with every release)
# An empty list serves to remove all policies from the entity
# This pattern assumes entities will belong to groups that grant effective policies,
#  and that most policies should NOT be assigned directly to entities,
#  as direct assignment of policies to entities is less scalable than leveraging groups
declare defpolicy="global-default,entity-default"

# Some options
while getopts ":vdhqf:" opt; do
  case ${opt} in
    v)
      # Verbosity level
      declare -i v=$((${v} + 1))
      [[ ${v} -ge 1 ]] && echo "Verbosity level set to ${v}"
      ;;
    f)
      # Fully-Qualified Domain Name (FQDN)
      declare domain="${OPTARG}"
      [[ ${v} -ge 1 ]] && echo "Domain set to ${OPTARG}"
      ;;
    d)
      # Dry-Run
      declare -i d=$((${d} + 1))
      [[ ${v} -ge 1 ]] && echo "Dry Run enabled!"
      ;;
    q)
      # Quick Run
      declare -i q=$((${q} + 1))
      [[ ${v} -ge 1 ]] && echo "Quick Run enabled!"
      ;;
    h|?)
      usage
      ;;
    :)
      echo "Option -${OPTARG} requires an argument." >&2
      exit 1
      ;;
  esac
done

if [ -z "${domain:-}" ] || [ "${domain}" = '' ] ; then
    echo "FQDN (-f) must be set." >&2
    exit 1
fi

# Grab best token
if [ -z "${VAULT_TOKEN:-}" ] || [ "${VAULT_TOKEN}" = '' ] ; then
    declare token=$( cat ~/.vault-token )
else
    declare token=${VAULT_TOKEN}
fi
declare token=$(echo ${token} | sed -e 's/"//g')
export VAULT_TOKEN=${token}

# Check for presence of binaries in container
declare -a binaries=('vault' 'jq' 'date')
for bin in ${binaries[@]} ; do
  declare var=$( type ${bin} 2>&1 | grep --count --regexp="not found" )
  if [[ ${var} -ge 1 ]]; then
    echo "${bin} binary not available, terminating script"
    exit 10
  else
    [[ ${v} -ge 1 ]] && echo "Binary ${bin} found!"
  fi
done

# Test if script can authenticate against Vault
set +e
vault token lookup > /dev/null 2>&1
if [ ${?} != 0 ] ; then
  echo "Cannot auth to Vault"
  echo "IP Address: $(hostname -I | awk '{print $1}')" # useful for troubleshooting if made into a CI job
  vault token lookup 2>&1
  exit 11
fi
[[ ${v} -ge 1 ]] && echo "Authenticated against Vault"
set -o errexit

# Get entity list
if [[ ${q} -ge 1 ]] ; then
  declare entity_array=(`
    vault list -format=json identity/entity/name |
    jq ".[]" |
    sed -e "s/\" \"/ /g" |
    sed -e "s/^\"//" |
    sed -e "s/\"$//" |
    tr " " "\n"
  `)
  declare entity_array=(`echo ${entity_array[@]} | grep -o -e "entity_[^ ]*"`)
else
  declare entity_array=(`
    vault list -format=json identity/entity/id |
    jq ".[]" |
    sed -e "s/\" \"/ /g" |
    sed -e "s/^\"//" |
    sed -e "s/\"$//" |
    tr " " "\n"
  `)
fi
[[ ${v} -ge 1 ]] && echo "Pulled Entity ID List: ${#entity_array[@]}"

# Case: No entities in Quick Run
if [[ ${q} -ge 1 ]] && ([ -z "${entity_array:-}" ] || [ "${entity_array-}" = '' ]) ; then
  [[ ${v} -ge 1 ]] && echo "No entities in Quick Run, exiting successfully"
  exit 0
fi

[[ ${v} -ge 2 ]] && echo "Pulled Entity ID List: ${entity_array[@]}"

[[ ${v} -ge 1 ]] && echo "Get Approle Role-IDs"
declare approle_array=(`
  vault list -format=json auth/approle/role |
  jq ".[]" |
  sed -e "s/\" \"/ /g" |
  sed -e "s/^\"//" |
  sed -e "s/\"$//" |
  tr " " "\n"
`)
for ar in ${approle_array[@]-} ; do
  # Must change hyphens to underscores for dynamic var names for support with Bash 3x
  # Creating array because reverse-lookup doesn't exist on the Vault API or CLI
  declare arid=$(
    vault read -format=json auth/approle/role/${ar}/role-id |
    jq ".data.role_id" |
    sed -e 's/"//g' |
    sed -e 's/-/_/g'
  )
  declare "ar_${arid}_name"="${ar}"
done
declare -a alert_array=()
for ent in ${entity_array[@]-} ; do
  [[ ${v} -ge 1 ]] && echo "=====Begin Entity Loop====="
  [[ ${v} -ge 1 ]] && echo "Entity: ${ent}"
  if [[ ${q} -ge 1 ]] ; then
    declare ent=$(
      vault read -format=json identity/entity/name/${ent} |
      jq ".data.id" |
      sed -e 's/"//g'
    )
  fi
  declare entity=$(vault read -format=json identity/entity/id/${ent})
  [[ ${d} -eq 0 ]] && vault write identity/entity/id/${ent} policies=${defpolicy}
  declare -a entity_alias_id_array=(` echo ${entity} | jq ".data.aliases[].id" | sed 's/"//g' | tr "\n" " "`)
  declare -i alias_count=${#entity_alias_id_array[@]}
  [[ ${v} -ge 2 ]] && echo "Number of associated aliases: ${alias_count}"
  declare ent_name=$( echo ${entity} | jq ".data.name" | sed -e 's/"//g' )
  [[ ${v} -ge 1 ]] && echo "Entity Name: ${ent_name}"
  if [[ $alias_count -ge 1 ]] ; then
    for alid in ${entity_alias_id_array[@]-} ; do
      [[ ${v} -ge 1 ]] && echo "===  Begin Alias Loop   ==="
      # Check naming convention, do nothing if good, delete entity if bad & 'continue'
      declare al=$(vault read -format=json identity/entity-alias/id/${alid})
      declare al_name=$(echo ${al} | jq ".data.name" | sed -e 's/"//g')
      declare al_last_modified=$(echo ${al} | jq ".data.last_update_time" | sed -e 's/"//g')
      declare al_mount_type=$(echo ${al} | jq ".data.mount_type" | sed -e 's/"//g')
      if [[ "${al_mount_type}" =~ (okta) ]] ; then
        declare al_name=$(echo ${al_name} | grep -o "^[^@]*")
      fi
      declare yesterday=$(date --date="1 day ago" +"%Y-%m-%dT%H:%M:%S.000000000Z")
      if [[ "${al_mount_type}" =~ (ldap|okta|userpass) ]] ; then
        declare usual_ent=$(vault read -format=json identity/entity/name/${al_name}-AT-${domain} 2>&1)
        declare entname_test="nevermatch" # Some tests need a bound variable for this var
      elif [[ "${al_mount_type}" =~ (aws|azure|token) ]] ; then
        declare entname_test="${al_mount_type}_${al_name}"
        declare usual_ent=$(vault read -format=json identity/entity/name/${entname_test} 2>&1)
      elif [[ "${al_mount_type}" =~ (approle) ]] ; then
        declare varname=$(echo "ar_${al_name}_name" | sed -e 's/-/_/g')
        declare approle_name="${!varname}" # Indirect Expansion - Creating a dynamically named variable
        declare entname_test="${al_mount_type}_${approle_name}"
        declare usual_ent=$(vault read -format=json identity/entity/name/${entname_test} 2>&1)
      else
        [[ ${v} -ge 1 ]] && echo "Auth Mount Type not supported: ${al_mount_type}"
        continue
      fi
      declare canid=$(echo ${usual_ent} | jq ".data.id" 2>&1 | sed -e 's/"//g')
      [[ ${v} -ge 1 ]] && echo "Alias Name:     ${al_name}"
      [[ ${v} -ge 1 ]] && echo "Alias ID:       ${alid}"
      [[ ${v} -ge 2 ]] && echo "Entity Name:    ${ent_name}"
      [[ ${v} -ge 2 ]] && echo "Yesterday:      ${yesterday}"
      [[ ${v} -ge 2 ]] && echo "Alias Last Mod: ${al_last_modified}"
      if [ "${al_name}-AT-${domain}" == "${ent_name}" ] ; then
        [[ ${v} -ge 1 ]] && echo "Alias and Entity naming conventions match; user ${ent_name}"
      elif [ "${entname_test}" == "${ent_name}" ] ; then
        [[ ${v} -ge 1 ]] && echo "Approle, AWS and Azure naming conventions match; authmethod ${ent_name}"
      elif [[ "${al_mount_type}" =~ (ldap|okta|userpass) ]] ; then
        [[ ${v} -ge 1 ]] && echo "Name mismatch, ${al_mount_type} entity: ${ent_name}"
        if [[ ${usual_ent} =~ ^No\ value\ found\ at.* ]] ; then
          [[ ${v} -ge 1 ]] && echo "Renaming to match standard: ${ent_name} to ${al_name}-AT-${domain}"
          [[ ${d} -eq 0 ]] && vault write identity/entity/id/${ent} name="${al_name}-AT-${domain}" policies=${defpolicy}
        else
          # Update to proper canonical
          [[ ${v} -ge 1 ]] && echo "Updating Canonical ID of Alias to ${canid}"
          [[ ${d} -eq 0 ]] && vault write identity/entity-alias/id/${alid} canonical_id=${canid}
          # Disabled this because there may be more than one entity-alias tied to entity; this will have to be caught next run
          #[[ ${v} -ge 1 ]] && echo "Deleting newly orphaned Entity ${ent}"
          #[[ ${d} -eq 0 ]] && vault delete -format=json identity/entity/id/${ent}
        fi
      elif [[ "${al_mount_type}" =~ (approle) ]] ; then
        [[ ${v} -ge 1 ]] && echo "Should rename ${al_mount_type} entity: ${ent_name}"
        if [[ ${usual_ent} =~ ^No\ value\ found\ at.* ]] ; then
          # Makes Approle Entity Names predictable, which can be useful elsewhere
          [[ ${v} -ge 1 ]] && echo "Renaming to match standard: ${ent_name} to ${al_mount_type}_${approle_name}"
          [[ ${d} -eq 0 ]] && vault write -format=json identity/entity/id/${ent} name="${al_mount_type}_${approle_name}"
        else
          # Assign new canonical id & delete newly orphaned entity
          [[ ${v} -ge 1 ]] && echo "Updating Canonical ID of Alias: ${al_name} to entity named: $(echo ${usual_ent} | jq '.data.name')"
          [[ ${d} -eq 0 ]] && vault write -format=json identity/entity-alias/id/${alid} canonical_id=${canid}
          # Disabled this because there may be more than one entity-alias tied to entity; this will have to be caught next run
          #[[ ${v} -ge 1 ]] && echo "Deleting newly orphaned Entity ${ent}"
          #[[ ${d} -eq 0 ]] && vault delete -format=json identity/entity/id/${ent}
        fi
      elif [[ "${yesterday}" > "${al_last_modified}" ]] && [[ "${al_mount_type}" =~ (aws|azure) ]] ; then
        #TODO: test the auth will still work if entity and entity-alias are deleted for aws|azure methods
        [[ ${v} -ge 2 ]] && echo "Should delete ${al_mount_type} entity: ${ent_name}"
        #[[ ${d} -eq 0 ]] && vault delete identity/entity/id/$ent
        #[[ ${d} -eq 0 ]] && vault delete identity/entity-alias/id/${alid}
      elif [[ "${yesterday}" < "${al_last_modified}" ]] && [[ "${al_mount_type}" =~ (aws|azure) ]] ; then
        # In-Use case - rename to standard
        [[ ${v} -ge 1 ]] && echo "Should rename ${al_mount_type} entity: ${ent_name} to standard: ${entname_test}"
        [[ ${d} -eq 0 ]] && vault write -format=json identity/entity/id/${ent} name="${entname_test}"
      else
        [[ ${v} -ge 2 ]] && echo "No other logic match: ${ent_name}"
      fi
      [[ ${v} -ge 1 ]] && echo "===   End  Alias Loop   ==="
    done
  else # Zero Alias Case, $alias_count -eq 0
    [[ ${v} -ge 1 ]] && echo "Should delete orphan entity: ${ent_name}"
    [[ ${d} -eq 0 ]] && vault delete identity/entity/id/${ent}
  fi
  [[ ${v} -ge 1 ]] && echo "===== END  Entity Loop====="
done

echo "Alert Array:"
echo "${alert_array[@]-}"
exit 0
