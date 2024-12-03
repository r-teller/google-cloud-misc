!/bin/bash

sort_array() {
    local current_array="${1}"
    local items_to_move="${2}"
    local position="${3^^}"
    local sorted_result=()
    local valid_to_move=()

    # If this function is used to sort two arrays return results in Upper case
    if [[ -n "$items_to_move" ]]; then
        current_array=($(echo "${current_array[@]}" | tr '[:lower:]' '[:upper:]'))
        items_to_move=($(echo "${items_to_move[@]}" | tr '[:lower:]' '[:upper:]'))
    fi

    # Default to "front" if position is not defined
    if [[ -z "$position" ]]; then
        position="FRONT"
    fi

    # Add items from current_array to sorted_result, excluding items in items_to_move
    for item in ${current_array[@]}; do
        if [[ ! " ${sorted_result[@]} " =~ " $item " && ! " ${items_to_move[@]} " =~ " $item " ]]; then
            sorted_result+=("$item")
        fi
    done

    # Identify items from items_to_move that are present in current_array
    for item in ${items_to_move[@]}; do
        if [[ ! " ${valid_to_move[@]} " =~ " $item " && " ${current_array[@]} " =~ " $item " ]]; then
            valid_to_move+=("$item")
        fi
    done

    # Sort sorted_result alphabetically
    sorted_result=($(echo "${sorted_result[@]}" | tr ' ' '\n' | sort))

    # If flag is 'front', place A at the front
    if [ "$position" == "FRONT" ]; then
        result=("${valid_to_move[@]}" "${sorted_result[@]}")
    # If flag is 'back', place A at the back
    elif [ "$position" == "BACK" ]; then
        result=("${sorted_result[@]}" "${valid_to_move[@]}")
    else
        echo "Invalid flag. Use 'front' or 'back'. instead of ${position}"
        exit 1
    fi

    echo ${result[@]}
}

# List of supported dependencies
SUPPORTED_DEPENDENCIES=("Firewall_Rules" "Subnetworks" "Routes" "Cloud_Routers" "PSA_Ranges" "Internal_Addresses" "Serverless_Connectors")
ORDER_DEPENDENCIES_COLLECT=("Subnetworks")
ORDER_DEPENDENCIES_DELETE=("Cloud_Routers" "Internal_Addresses" "Subnetworks")

ORDERED_DEPENDENCIES_COLLECT=$(sort_array "${SUPPORTED_DEPENDENCIES[*]}" "${ORDER_DEPENDENCIES_COLLECT[*]}" "front")
ORDERED_DEPENDENCIES_DELETE=$(sort_array "${SUPPORTED_DEPENDENCIES[*]}" "${ORDER_DEPENDENCIES_DELETE[*]}" "back")
ORDERED_DEPENDENCIES_SORT=$(sort_array "${SUPPORTED_DEPENDENCIES[*]}")

# Function to display help message
usage() {
    echo "Usage: $0 -p|--project PROJECT_ID -n|--network NETWORK_NAME [-d|--dry-run] [-t|--table] [-r|--delete]"
    echo "  -p, --project PROJECT_ID     Google Cloud project ID"
    echo "  -n, --network NETWORK_NAME   Google Cloud network name"
    echo "  -d, --dry-run                Dry run flag"
    echo "  -t, --table                  Table output list of all referenced items"
    echo "  -r, --delete                 Delete dependencies and the network"
    echo "  -f, --filter-dependencies    Comma-separated list of dependencies to collect/delete with (supported: ${ORDERED_DEPENDENCIES_SORT}).  If omitted, all dependencies are in-scope, filtering prevents deletion of Network."
    exit 1
}

# Check if the user has the required tools installed
if ! command -v gcloud &>/dev/null; then
    echo "gcloud could not be found. Please install the Google Cloud SDK."
    exit 1
fi

# Initialize variables
DRY_RUN=false
TABLE_OUTPUT=false
DELETE=false

# Parse input arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    -p | --project)
        PROJECT_ID="$2"
        shift 2
        ;;
    -n | --network)
        NETWORK_NAME="$2"
        shift 2
        ;;
    -f | --filter-dependencies)

        DEPENDENCIES="$2"
        shift 2
        ;;
    -d | --dry-run)
        DRY_RUN=true
        shift
        ;;
    -t | --table)
        TABLE_OUTPUT=true
        shift
        ;;
    -r | --delete)
        DELETE=true
        shift
        ;;
    *)
        usage
        ;;
    esac
done

# Validate required arguments
if [ -z "$PROJECT_ID" ] || [ -z "$NETWORK_NAME" ]; then
    usage
fi

if [ -n "$DEPENDENCIES" ]; then
    IFS=',' read -r -a FILTERED_DEPENDENCIES <<<"$(echo "$DEPENDENCIES" | tr '[:lower:]' '[:upper:]')"

    # Convert Supported Dependencies to upper case to reduce case conflicts
    UPPER_SUPPORTED_DEPENDENCIES=($(echo "${SUPPORTED_DEPENDENCIES[@]}" | tr '[:lower:]' '[:upper:]'))

    UNKNOWN_DEPENDENCIES=()

    # Collect the ordered dependencies first
    for DEPENDENCY in "${FILTERED_DEPENDENCIES[@]}"; do
        if [[ ! " ${UPPER_SUPPORTED_DEPENDENCIES[@]} " =~ " $DEPENDENCY " ]]; then
            echo "Foo not => ${DEPENDENCY}"
            UNKNOWN_DEPENDENCIES+=("$DEPENDENCY")
        fi
    done
    if [ -n "$UNKNOWN_DEPENDENCIES" ]; then
        echo -e "Error: Unknown dependencies specified: ${UNKNOWN_DEPENDENCIES[@]}\n"
        usage
    fi
    ORDER_FILTERED_DEPENDENCIES_COLLECT=$(sort_array "${FILTERED_DEPENDENCIES[*]}" "${ORDER_DEPENDENCIES_COLLECT[*]}" "front")
    ORDER_FILTERED_DEPENDENCIES_DELETE=$(sort_array "${FILTERED_DEPENDENCIES[*]}" "${ORDER_DEPENDENCIES_DELETE[*]}" "back")
fi

# Primary function to collect network dependencies
collect_dependencies() {
    # Helper function to collect the specific dependencies
    collect_dependency() {
        case "$1" in
        FIREWALL_RULES) collect_firewall_rules ;;
        SUBNETWORKS) collect_subnetworks ;;
        CLOUD_ROUTERS) collect_cloud_routers ;;
        ROUTES) collect_routes ;;
        SERVERLESS_CONNECTORS) collect_serverless_connectors ;;
        INTERNAL_ADDRESSES) collect_internal_addresses ;;
        PSA_RANGES) collect_psa_ranges ;;
        esac
    }

    if [ ! -v DEPENDENCIES ]; then
        for DEPENDENCY in ${ORDERED_DEPENDENCIES_COLLECT[@]}; do
            collect_dependency "$DEPENDENCY"
        done
    else
        for DEPENDENCY in ${ORDER_FILTERED_DEPENDENCIES_COLLECT[@]}; do
            collect_dependency "$DEPENDENCY"
        done
    fi
}

# Function to collect firewall rules
collect_firewall_rules() {
    FIREWALL_RULES=$(gcloud compute firewall-rules list --project="$PROJECT_ID" --filter="network~/$NETWORK_NAME" --format="value(name)" | tr '\n' '\n')
}

# Function to collect subnetworks
collect_subnetworks() {
    SUBNETWORKS=$(gcloud compute networks subnets list --project="$PROJECT_ID" --filter="network~/$NETWORK_NAME" --format="csv[no-heading](name,region)" | tr '\n' '\n')
}

# Function to collect internal addresses
collect_internal_addresses() {
    # Collect internal IP addresses by querying instances in the specified network
    if [ ! -v SUBNETWORKS ]; then
        # Handles dependcy of subnetworks if not explitly called out during collection input
        collect_subnetworks
    fi

    if [ -n "$SUBNETWORKS" ]; then
        while IFS=',' read -r SUBNETWORK REGION; do
            ADDRESSES=$(gcloud compute addresses list --project="$PROJECT_ID" --filter="subnetwork~/$SUBNETWORK" --format="csv[no-heading](name,region)" | tr '\n' '\n')

            # Append the collected addresses to the INTERNAL_ADDRESSES variable
            if [ -n "$ADDRESSES" ]; then
                INTERNAL_ADDRESSES+="$ADDRESSES"
            fi
        done <<<"$SUBNETWORKS"
    fi
}

# Function to collect serverless connectors
collect_serverless_connectors() {
    # It is possible to create a serverless connector but not have the subnet returned via gcloud compute subnets list
    # Extract all subnetworks from the specified network
    SUBNETWORK_REGIONS=$(gcloud compute networks describe "$NETWORK_NAME" --format="flattened(subnetworks[].segment(8))" | awk '{print $2}' | sort -u)
    if [ -n "$SUBNETWORK_REGIONS" ] && [ "$SUBNETWORK_REGIONS" != "None" ]; then
        for REGION in $SUBNETWORK_REGIONS; do
            CONNECTORS=$(gcloud compute networks vpc-access connectors list --project="$PROJECT_ID" --region="$REGION" --filter="network=$NETWORK_NAME" --format="csv[no-heading](name,name.segment(3))" | tr '\n' '\n')
            if [ -n "$CONNECTORS" ]; then
                SERVERLESS_CONNECTORS+="$CONNECTORS"
            fi
        done
    fi
}

# Function to collect static routes
collect_routes() {
    ROUTES=$(gcloud compute routes list --project="$PROJECT_ID" --filter="network~/$NETWORK_NAME AND NOT (nextHopNetwork:* OR nextHopPeering:*)" --format="value(name)" | tr '\n' '\n')
}

# Function to collect cloud routers
collect_cloud_routers() {
    CLOUD_ROUTERS=$(gcloud compute routers list --project="$PROJECT_ID" --filter="network~/$NETWORK_NAME" --format="csv[no-heading](name,region)" | tr '\n' '\n')
}

# Function to collect private service access ranges
collect_psa_ranges() {
    PSA_RANGES=$(gcloud compute addresses list --project="$PROJECT_ID" --filter="purpose=VPC_PEERING AND network=$NETWORK_NAME" --format="value(name)" | tr '\n' '\n')
}

# Function to list dependencies
list_dependencies() {
    if [ -z "$DEPENDENCIES" ]; then
        echo "Listing ALL dependencies for network: $NETWORK_NAME"
    else
        echo "Listing FILTERED dependencies ($DEPENDENCIES) for network: $NETWORK_NAME"
    fi

    for DEPENDENCY in ${ORDERED_DEPENDENCIES_COLLECT[@]}; do
        # Check if the dependency is in the list of filtered dependencies, or if no filter is applied
        if [[ ${#FILTERED_DEPENDENCIES[@]} -gt 0 && " ${FILTERED_DEPENDENCIES[@]} " =~ " $DEPENDENCY " ]] || [ ${#FILTERED_DEPENDENCIES[@]} -eq 0 ]; then
            case "$DEPENDENCY" in
            FIREWALL_RULES)
                if [ "$TABLE_OUTPUT" = true ]; then
                    echo "Firewall Rules:"
                    if [ -n "$FIREWALL_RULES" ]; then
                        echo -e "$FIREWALL_RULES\n"
                    else
                        echo -e "None\n"
                    fi
                else
                    echo -e "Firewall Rules: ${FIREWALL_RULES:-None}\r\n"
                fi
                ;;
            PSA_RANGES)
                if [ "$TABLE_OUTPUT" = true ]; then
                    echo "PSA Ranges:"
                    if [ -n "$PSA_RANGES" ]; then
                        echo -e "$PSA_RANGES\n"
                    else
                        echo -e "None\n"
                    fi
                else
                    echo -e "PSA Ranges: ${PSA_RANGES:-None}\r\n"
                fi
                ;;
            SERVERLESS_CONNECTORS)
                if [ "$TABLE_OUTPUT" = true ]; then
                    echo "Serverless Connectors:"
                    if [ -n "$SERVERLESS_CONNECTORS" ]; then
                        echo "$SERVERLESS_CONNECTORS" | sed 's/,/ (Region: /; s/$/)/; $s/$/\n/'
                    else
                        echo -e "None\n"
                    fi
                else
                    echo -e "Serverless Connectors: ${SERVERLESS_CONNECTORS:-None}\r\n"
                fi
                ;;
            SUBNETWORKS)
                if [ "$TABLE_OUTPUT" = true ]; then
                    echo "Subnetworks:"
                    if [ -n "$SUBNETWORKS" ]; then
                        echo "$SUBNETWORKS" | sed 's/,/ (Region: /; s/$/)/; $s/$/\n/'
                    else
                        echo -e "None\n"
                    fi
                else
                    echo -e "Subnetworks: ${SUBNETWORKS:-None}\r\n"
                fi
                ;;
            INTERNAL_ADDRESSES)
                if [ "$TABLE_OUTPUT" = true ]; then
                    echo "Internal Addresses:"
                    if [ -n "$INTERNAL_ADDRESSES" ]; then
                        echo "$INTERNAL_ADDRESSES" | sed 's/,/ (Region: /; s/$/)/; $s/$/\n/'
                    else
                        echo -e "None\n"
                    fi
                else
                    echo -e "Internal Addresses: ${INTERNAL_ADDRESSES:-None}\r\n"
                fi
                ;;
            CLOUD_ROUTERS)
                if [ "$TABLE_OUTPUT" = true ]; then
                    echo "Cloud Routers:"
                    if [ -n "$CLOUD_ROUTERS" ]; then
                        echo "$CLOUD_ROUTERS" | sed 's/,/ (Region: /; s/$/)/; $s/$/\n/'
                    else
                        echo -e "None\n"
                    fi
                else
                    echo -e "Cloud Routers: ${CLOUD_ROUTERS:-None}\r\n"
                fi
                ;;
            ROUTES)
                if [ "$TABLE_OUTPUT" = true ]; then
                    echo "Routes:"
                    if [ -n "$ROUTES" ]; then
                        echo -e "$ROUTES\n"
                    else
                        echo -e "None\n"
                    fi
                else
                    echo -e "Routes: ${ROUTES:-None}\r\n"
                fi
                ;;
            *)
                echo "Error: Unsupported dependency type $DEPENDENCY"
                ;;
            esac
        fi
    done
}

# Function to delete dependencies
delete_dependencies() {
    if [ -z "$DEPENDENCIES" ]; then
        echo "Deleting ALL dependencies and network for : $NETWORK_NAME"
    else
        echo "Deleting FILTERED dependencies ($DEPENDENCIES) for network: $NETWORK_NAME"
    fi

    # Loop through each supported dependency type
    for DEPENDENCY in ${ORDERED_DEPENDENCIES_DELETE[@]}; do
        # Check if the dependency is in the list of filtered dependencies, or if no filter is applied
        if [[ ${#FILTERED_DEPENDENCIES[@]} -gt 0 && " ${FILTERED_DEPENDENCIES[@]} " =~ " $DEPENDENCY " ]] || [ ${#FILTERED_DEPENDENCIES[@]} -eq 0 ]; then
            case "$DEPENDENCY" in
            FIREWALL_RULES)
                if [ -n "$FIREWALL_RULES" ]; then
                    printf '%s\n' "$FIREWALL_RULES" | while read -r FW; do
                        echo "Deleting firewall rule: $FW"
                        gcloud compute firewall-rules delete "$FW" --quiet
                    done
                else
                    echo "No firewall rules to delete"
                fi
                ;;
            PSA_RANGES)
                if [ -n "$PSA_RANGES" ]; then
                    printf '%s\n' "$PSA_RANGES" | while read -r RANGE; do
                        echo "Deleting PSA range: $RANGE"
                        gcloud compute addresses delete "$RANGE" --quiet
                    done
                else
                    echo "No PSA ranges to delete"
                fi
                ;;
            SERVERLESS_CONNECTORS)
                if [ -n "$SERVERLESS_CONNECTORS" ]; then
                    printf '%s\n' "$SERVERLESS_CONNECTORS" | while IFS=',' read -r CONNECTOR REGION; do
                        echo "Deleting serverless connector: $CONNECTOR in region $REGION"
                        gcloud compute networks vpc-access connectors delete "$CONNECTOR" --region="$REGION" --quiet
                    done
                else
                    echo "No serverless connectors to delete"
                fi
                ;;
            SUBNETWORKS)
                if [ -n "$SUBNETWORKS" ]; then
                    printf '%s\n' "$SUBNETWORKS" | while IFS=',' read -r SUBNET REGION; do
                        echo "Deleting subnet: $SUBNET in region $REGION"
                        gcloud compute networks subnets delete "$SUBNET" --region="$REGION" --quiet
                    done
                else
                    echo "No subnets to delete"
                fi
                ;;
            INTERNAL_ADDRESSES)
                if [ -n "$INTERNAL_ADDRESSES" ]; then
                    printf '%s\n' "$INTERNAL_ADDRESSES" | while IFS=',' read -r ADDRESS REGION; do
                        echo "Deleting internal IP address: $ADDRESS in region $REGION"
                        gcloud compute addresses delete "$ADDRESS" --region="$REGION" --quiet
                    done
                else
                    echo "No internal IP addresses to delete"
                fi
                ;;
            CLOUD_ROUTERS)
                if [ -n "$CLOUD_ROUTERS" ]; then
                    printf '%s\n' "$CLOUD_ROUTERS" | while IFS=',' read -r ROUTER REGION; do
                        echo "Deleting cloud router: $ROUTER in region $REGION"
                        gcloud compute routers delete "$ROUTER" --region="$REGION" --quiet
                    done
                else
                    echo "No cloud routers to delete"
                fi
                ;;
            ROUTES)
                if [ -n "$ROUTES" ]; then
                    printf '%s\n' "$ROUTES" | while read -r ROUTE; do
                        echo "Deleting route: $ROUTE"
                        gcloud compute routes delete "$ROUTE" --quiet
                    done
                else
                    echo "No routes to delete"
                fi
                ;;
            *)
                echo "Error: Unsupported dependency type $DEPENDENCY"
                ;;
            esac
        fi
    done
}

# Main logic
if [ "$DRY_RUN" = true ]; then
    echo "Dry run mode enabled"
    collect_dependencies
    list_dependencies
elif [ "$DELETE" = true ]; then
    collect_dependencies
    delete_dependencies
    if [ ${#FILTERED_DEPENDENCIES[@]} -eq 0 ]; then
        echo "Deleting network: $NETWORK_NAME"
        gcloud compute networks delete $NETWORK_NAME --quiet
    fi
else
    usage
fi
