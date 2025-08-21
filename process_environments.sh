#!/bin/zsh

# Source functions from external file
source "$(dirname "$0")/includes/functions.sh"

# Source configuration constants
source "$(dirname "$0")/includes/conf.sh"

# Authenticate
MAGENTO_CLOUD_CLI_TOKEN="$MAGENTO_CLOUD_CLI_TOKEN" magento-cloud auth:api-token-login

[[ ! -f "$CSV_FILE" ]] && { log ERROR "CSV $CSV_FILE missing!"; exit 1; }

print_info "------- Reading CSV file -------"

# CSV header for report
echo "EnvID,Environment Status,Branch,URL,URL Status,Before Redeploy Status,HTTP Access,After Redeploy Status" > "$STATUS_REPORT"

# Read project IDs (skip header row in environments.csv)
env_ids=($(tail -n +2 "$CSV_FILE"))

# Iterate through all environment IDs from the CSV file
for env_id in "${env_ids[@]}"; do
    # Trim whitespace
    # xargs trims leading/trailing whitespace
    env_id=$(echo "$env_id" | xargs)

    # Skip empty env_id
    [[ -z "$env_id" ]] && continue

    # Process project message
    log INFO "Processing project: $env_id"

    # Get branches
    branches=$(magento-cloud environments --project="$env_id" --pipe)
    if [[ -z "$branches" ]]; then
        log WARN "No branches for $env_id"
        continue
    fi

    # Print branches
    log INFO 'Branches:'
    echo "$branches" | sed 's/^/   - /'

    IFS=$'\n'
    for branch in $branches; do
        # Skip empty branches
        [[ -z "$branch" ]] && continue
        log INFO "Checking branch: $branch"

        # Get environment info in plain format
        env_status=$(magento-cloud environment:info status \
            --project="$env_id" --environment="$branch" --format=plain)

        # Trim whitespace
        # xargs trims leading/trailing whitespace
        env_status=$(echo "$env_status" | xargs)

        # Skip empty env_status
        [[ -z "$env_status" ]] && continue

        # If still empty, mark unknown
        if [[ -z "$env_status" ]]; then
            env_status="unknown"
        fi

        # Skip non-active environments (case-insensitive)
        env_status_lc=$(echo "$env_status" | tr '[:upper:]' '[:lower:]')
        if [[ "$env_status_lc" != "active" ]]; then
            log WARN "Skipping branch $branch (environment status: $env_status)"
            echo "$env_id,$env_status,$branch,-,skipped,skipped,skipped,skipped" >> "$STATUS_REPORT"
            continue
        fi

        # Get environment URL
        url=$(magento-cloud environment:info edge_hostname \
            --project="$env_id" --environment="$branch" --format=plain)

        summary_status=""
        summary_htaccess=""
        summary_after=""

        # Check if the 'url' variable is non-empty and not equal to "null".
        if [[ -n "$url" && "$url" != "null" ]]; then
            log OK "Env URL: $url"
            url_status="url_ok"
            summary_status="url_ok"
        else
            log WARN "No URL for $env_id/$branch"
            url_status="url_missing"
            echo "$env_id,$env_status,$branch,$url,$url_status,url_missing,skipped,skipped" >> "$STATUS_REPORT"
            continue
        fi

        # Get activity status
        activity_csv=$(magento-cloud activity:list --project="$env_id" --environment="$branch" --limit=1 --format=csv)

        # Extract "Result" column value, handle quoted fields
        activity_status=$(echo "$activity_csv" | awk -F, '
            NR==1 {for(i=1;i<=NF;i++) if($i=="Result") col=i; next}
            NR==2 && col {gsub(/\"/, "", $col); print $col}')

        # Log activity status
        log INFO "Activity: $activity_status"

        # Check if activity was successful
        if [[ "$activity_status" == "success" ]]; then
            # Check URL status
            status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 30 "$url" 2>/dev/null)

            log INFO "URL Health Status: $status"

            # Check if the URL is accessible
            if [[ "$status" -eq 200 ]]; then
                log OK "URL healthy (200)"
                log INFO "Enabling HTTP access..."

                # Enable HTTP access
                magento-cloud httpaccess --project="$env_id" --environment="$branch" --enabled=1 --auth="${LOGIN}:${PASSWORD}" --yes

                # Redeploy environment in background
                magento-cloud redeploy --project="$env_id" --environment="$branch" --yes --no-wait &
                pids+=($!)
                log INFO "Triggered redeploy for $env_id/$branch in background (PID $!)"

                # Set URL status
                summary_htaccess="enabled_now"

                # Get activity status
                activity_csv_after=$(magento-cloud activity:list --project="$env_id" --environment="$branch" --limit=1 --format=csv)

                # Extract "Result" column value, handle quoted fields
                summary_after=$(echo "$activity_csv" | awk -F, '
                    NR==1 {for(i=1;i<=NF;i++) if($i=="Result") col=i; next}
                    NR==2 && col {gsub(/\"/, "", $col); print $col}')
                summary_status="healthy"
            else
                # Double checking of HTTP access is enabled via magento-cloud cli command
                if [[ "$status" -eq 401 ]]; then
                    log INFO "HTTP access already enabled."
                    summary_status="healthy"
                    summary_htaccess="enabled_already"
                else
                    # Get HTTP access status
                    httpaccess_enabled=$(magento-cloud httpaccess --project="pdtbrejumpyig" --environment="master" \
                        | grep 'is_enabled:' \
                        | awk -F: '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}'
                    )

                    log INFO "HTTP Access Status: $httpaccess_enabled"

                    # Check if HTTP access is enabled
                    if [[ "$httpaccess_enabled" == "true" ]]; then
                        log INFO "HTTP access already enabled."
                        summary_status="healthy"
                        summary_htaccess="enabled_already"
                    else
                        log ERROR "URL returned $status"
                        summary_status="unhealthy"
                        summary_htaccess="not_enabled"
                        summary_after="not_redeployed"
                    fi
                fi
                summary_after="not_redeployed"
            fi
        else 
            log WARN "Last activity not success"

            link="$url"
            if [[ "$url_status" != "url_ok" ]]; then
                link="url_missing"
            fi

            echo "$env_id,$env_status,$branch,$url,$url_status,$link,skipped,skipped" >> "$STATUS_REPORT"
            continue
        fi

    # Append environment status to the report
    echo "$env_id,$env_status,$branch,$url,$url_status,$summary_status,$summary_htaccess,$summary_after" >> "$STATUS_REPORT"
    done
    unset IFS
done

print_info " ------- CSV Processing Completed. Output: $STATUS_REPORT ------- "