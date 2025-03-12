# 🔄 Ask the User if They Want to Set Up Rclone Backup
if ! is_completed "Setup Rclone Backup"; then
    read -p "Would you like to set up automatic database backups with Rclone (Cloudflare R2)? (yes/no): " setup_rclone

    if [[ "$setup_rclone" == "yes" ]]; then
        echo "🔹 Installing Rclone..."
        retry_command "sudo apt install -y rclone"

        # Ask for Cloudflare R2 configuration details
        rclone_config_path="$HOME/.config/rclone/rclone.conf"
        mkdir -p "$(dirname "$rclone_config_path")"

        echo "🔹 Configuring Rclone for Cloudflare R2..."
        read -p "Enter your Cloudflare R2 Access Key ID: " access_key_id
        read -p "Enter your Cloudflare R2 Secret Access Key: " secret_access_key
        read -p "Enter your Cloudflare R2 Account ID: " account_id
        read -p "Enter your Cloudflare R2 Bucket Name: " r2_bucket
        read -p "Enter your Cloudflare R2 Folder Path (e.g., backups/database/): " r2_folder
        read -p "Enter your Cloudflare R2 Endpoint (e.g., https://<account_id>.r2.cloudflarestorage.com): " r2_endpoint

        # Create the Rclone config file
        sudo tee "$rclone_config_path" > /dev/null <<EOL
[mys3]
type = s3
provider = Cloudflare
access_key_id = $access_key_id
secret_access_key = $secret_access_key
region =
endpoint = $r2_endpoint
acl = private
EOL

        echo "✅ Rclone configuration saved to $rclone_config_path"

        # Get user input for backup settings
        read -p "Enter the database name: " db_name
        read -p "Enter the PostgreSQL username: " db_user
        read -p "Enter the PostgreSQL host: " db_host
        read -p "Enter the PostgreSQL port (default: 5432): " db_port
        db_port=${db_port:-5432} # Use default port if not provided
        read -sp "Enter the PostgreSQL password: " db_password
        echo ""  # Move to a new line

        read -p "Enter the backup directory path (default: /home/$USER/rclonebackup): " backup_dir
        backup_dir=${backup_dir:-"/home/$USER/rclonebackup"}

        # Ask user how many times per day to run backups
        read -p "How many times per day do you want to take a backup? (e.g., 1, 2, 3, etc.): " backup_frequency
        while ! [[ "$backup_frequency" =~ ^[0-9]+$ && "$backup_frequency" -gt 0 ]]; do
            echo "❌ Please enter a valid number (greater than 0)."
            read -p "How many times per day do you want to take a backup? (e.g., 1, 2, 3, etc.): " backup_frequency
        done

        # Generate cron schedule times based on the backup frequency
        backup_intervals=$((24 / backup_frequency)) # How many hours between backups
        cron_schedule=""

        for ((i = 0; i < 24; i += backup_intervals)); do
            cron_schedule+="$(printf "%02d" "$i") * * * * /bin/bash $HOME/rclone_backup.sh\n"
        done

        # Create backup script
        backup_script="$HOME/rclone_backup.sh"
        sudo tee "$backup_script" > /dev/null <<EOL
#!/bin/bash

# Set variables
BACKUP_DIR="$backup_dir"
DATE_FORMAT=\$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="backup_\${DATE_FORMAT}.sql"
LOG_FILE="/var/log/rclone_backup.log"
DB_NAME="$db_name"
DB_USER="$db_user"
DB_HOST="$db_host"
DB_PORT="$db_port"
DB_PASSWORD="$db_password"
S3_PATH="mys3:$r2_bucket/$r2_folder"

# Function to log messages
log_message() {
    echo "\$1"
    echo "\$1" >> "\$LOG_FILE"
}

# Create backup directory if it doesn't exist
mkdir -p "\$BACKUP_DIR"

# Start backup process
log_message "******************* Cloudflare R2 Database Backup ************************"
log_message "Backup started at \$(date)"
log_message "Creating backup file: \$BACKUP_FILE"

# Perform database backup
PGPASSWORD="\$DB_PASSWORD" pg_dump -U "\$DB_USER" -h "\$DB_HOST" -p "\$DB_PORT" -d "\$DB_NAME" -F plain > "\$BACKUP_DIR/\$BACKUP_FILE"

# Check if database backup was successful
if [ \$? -eq 0 ]; then
    log_message "Database backup created successfully"
    
    # Upload to Cloudflare R2
    rclone copy --s3-no-check-bucket --no-check-dest "\$BACKUP_DIR/\$BACKUP_FILE" "\$S3_PATH" >> "\$LOG_FILE" 2>&1
    
    # Check if rclone was successful
    if [ \$? -eq 0 ]; then
        log_message "Backup successfully uploaded to Cloudflare R2: \$BACKUP_FILE"
    else
        log_message "ERROR: Failed to upload backup to Cloudflare R2: \$BACKUP_FILE"
    fi
else
    log_message "ERROR: Database backup failed: \$BACKUP_FILE"
fi

# Log completion
log_message "Backup completed at \$(date)"
log_message "----------------------------------------"

# Optional: Clean up old local backup files (keep last 3 days)
find "\$BACKUP_DIR" -name "backup_*.sql" -mtime +3 -delete
EOL

        # Make script executable
        chmod +x "$backup_script"

        # Schedule the script in cron job
        echo "🔹 Setting up automatic backups $backup_frequency times per day..."
        (crontab -l | grep -v "$backup_script" ; echo -e "$cron_schedule") | crontab -

        log_progress "Setup Rclone Backup"
        echo "✅ Automatic database backup setup complete. Backups will be uploaded $backup_frequency times per day to Cloudflare R2."
    else
        echo "Skipping Rclone backup setup."
    fi
fi
