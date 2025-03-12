#!/bin/bash

set -e

LOG_FILE="setup_progress.log"
ERROR_LOG="setup_errors.log"

# Function to log progress
log_progress() {
    echo "$1" >> "$LOG_FILE"
}

# Function to check if a step is already completed
is_completed() {
    grep -Fxq "$1" "$LOG_FILE"
}

# Function to log errors without exiting
log_error() {
    echo "[ERROR] $1" >> "$ERROR_LOG"
    echo "[ERROR] $1"
}

# Retry function for critical commands
retry_command() {
    local cmd="$1"
    local retries=3
    local count=0

    while [ $count -lt $retries ]; do
        eval "$cmd" && return 0
        count=$((count + 1))
        sleep 2
        echo "Retrying ($count/$retries)..."
    done

    log_error "Failed after $retries attempts: $cmd"
    return 1
}

# Ensure setup progress log exists
touch "$LOG_FILE"

# 1️⃣ System Update (Skip if already completed)
if ! is_completed "System Update"; then
    retry_command "sudo apt update -y && sudo apt upgrade -y"
    log_progress "System Update"
fi

# 2️⃣ Install Dependencies
if ! is_completed "Install Dependencies"; then
    retry_command "sudo apt install -y software-properties-common curl git wget build-essential openssl ufw screen virtualenv python3 python3-pip libpq-dev nginx certbot python3-certbot-nginx rclone postgresql postgresql-contrib"
    log_progress "Install Dependencies"
fi

# 3️⃣ Configure Firewall
if ! is_completed "Configure Firewall"; then
    echo "Configuring UFW firewall rules..."

    retry_command "sudo ufw default deny incoming"
    retry_command "sudo ufw default allow outgoing"

    # Allow each port separately (to avoid argument errors)
    for port in 22 80 443 5432 8001; do
        retry_command "sudo ufw allow $port"
    done

    # Explicitly allow SSH (important for remote access & CI/CD deployments)
    retry_command "sudo ufw allow OpenSSH"

    # Force enable UFW without interactive prompt
    retry_command "sudo ufw --force enable"

    # Verify UFW status
    sudo ufw status verbose || log_error "UFW status check failed"

    log_progress "Configure Firewall"
    echo "Firewall configured successfully."
fi

# 4️⃣ Generate SSH Key and Add to Authorized Keys
SSH_KEY_PATH="$HOME/.ssh/id_rsa"
if ! is_completed "Generate SSH Key"; then
    if [ ! -f "$SSH_KEY_PATH" ]; then
        echo "🔹 Generating SSH Key for secure access..."
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" || log_error "Failed to generate SSH key"

        # Ensure SSH directory and correct permissions
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh

        # Add the public key to authorized_keys for SSH access
        cat "$SSH_KEY_PATH.pub" >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys

        echo "✅ SSH Key generated successfully!"
        echo "🔹 Copy the following private key and add it to GitHub Actions Secrets as 'SSH_PRIVATE_KEY_PROD':"
        echo "--------------------------------------------------"
        cat "$SSH_KEY_PATH"
        echo "--------------------------------------------------"

    else
        echo "✅ SSH key already exists. Skipping generation."
    fi
    log_progress "Generate SSH Key"
fi

# 6️⃣ Configure PostgreSQL
pg_version=$(psql -V | awk '{print $3}' | cut -d '.' -f1)
pg_hba_conf="/etc/postgresql/$pg_version/main/pg_hba.conf"
postgresql_conf="/etc/postgresql/$pg_version/main/postgresql.conf"

if ! is_completed "Configure PostgreSQL"; then
    sudo sed -i "s/^#listen_addresses = .*/listen_addresses = '*'/" "$postgresql_conf"
    sudo tee -a "$pg_hba_conf" > /dev/null <<EOL
host    all             all             0.0.0.0/0             md5
host    all             all             ::1/128               md5
EOL
    sudo systemctl restart postgresql
    sudo systemctl enable postgresql
    log_progress "Configure PostgreSQL"
fi

# 7️⃣ Ensure PostgreSQL is Running
if ! is_completed "Check PostgreSQL Status"; then
    if ! systemctl is-active --quiet postgresql; then
        log_error "PostgreSQL is not running, trying to start it..."
        sudo systemctl start postgresql || log_error "Failed to start PostgreSQL."
    fi
    log_progress "Check PostgreSQL Status"
fi

# 8️⃣ Create Database and User with Required Permissions
if ! is_completed "Create Database"; then
    read -p "Enter PostgreSQL username: " pg_user
    read -sp "Enter PostgreSQL password: " pg_password
    echo
    read -p "Enter database name: " db_name

    # Check if database and user already exist
    db_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name'")
    user_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$pg_user'")

    if [[ "$db_exists" == "1" && "$user_exists" == "1" ]]; then
        echo "Database '$db_name' and user '$pg_user' already exist. Skipping creation."
    else
        retry_command "sudo -u postgres psql -c 'CREATE DATABASE \"$db_name\";'"
        retry_command "sudo -u postgres psql -c 'CREATE USER \"$pg_user\" WITH ENCRYPTED PASSWORD '\''$pg_password'\'';'"
        retry_command "sudo -u postgres psql -c 'GRANT ALL PRIVILEGES ON DATABASE \"$db_name\" TO \"$pg_user\";'"

        # Grant additional permissions
        retry_command "sudo -u postgres psql -c 'ALTER ROLE \"$pg_user\" WITH SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS;'"
    fi

    log_progress "Create Database"
fi

# 9️⃣ Prompt User to Push Code via CI/CD Instead of Cloning
if ! is_completed "Push Code via CI/CD"; then
    read -p "Enter project directory name (where the code will be deployed): " project_dir

    # Inform user to push code via CI/CD
    echo "Please push your code to the VPS using CI/CD. Ensure that the repository is deployed to: /home/$project_dir"

    # Wait for confirmation
    while true; do
        read -p "Have you successfully pushed the code? (yes/no): " confirm_push
        if [[ "$confirm_push" == "yes" ]]; then
            break
        else
            echo "Waiting for code push. Please push your code and then type 'yes'."
        fi
    done

    # Verify that the directory exists
    if [ -d "/home/$project_dir" ]; then
        echo "Code has been successfully pushed to VPS."
        log_progress "Push Code via CI/CD"
    else
        log_error "Code push verification failed! Directory /home/$project_dir does not exist."
        exit 1
    fi
fi

# 🔟 Configure Nginx (Only If User Wants)
if ! is_completed "Configure Nginx"; then
    # Ask user if they want to enable SSL
    while true; do
        read -p "Do you want to enable SSL for this setup? (yes/no): " enable_ssl
        if [[ "$enable_ssl" == "yes" || "$enable_ssl" == "no" ]]; then
            break
        else
            echo "Invalid response. Please enter 'yes' or 'no'."
        fi
    done

    # Ask for domain and port
    read -p "Enter your domain name: " domain_name
    read -p "Enter the application port number (e.g., 8001): " app_port
    read -p "Enter Nginx config name (e.g., myapp): " nginx_file

    nginx_conf_path="/etc/nginx/conf.d/${nginx_file}.conf"

    # Create Nginx configuration
    sudo tee $nginx_conf_path > /dev/null <<EOL
server {
    listen 80;
    server_name $domain_name;

    location / {
        proxy_pass http://127.0.0.1:$app_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOL

    retry_command "sudo nginx -t"
    retry_command "sudo systemctl restart nginx"
    retry_command "sudo systemctl enable nginx"

    log_progress "Configure Nginx"
fi

# 🔟 Setup SSL (Only If User Chose Yes)
if [[ "$enable_ssl" == "yes" ]]; then
    if ! is_completed "Setup SSL"; then
        retry_command "sudo certbot --nginx -d \"$domain_name\" --non-interactive --agree-tos -m \"admin@$domain_name\""
        log_progress "Setup SSL"
    fi
fi


# 🔟 Add Project to Systemd Service (Optional - After Everything is Done)
if ! is_completed "Setup Systemd Service"; then
    read -p "Would you like to set up this project as a systemd service? (yes/no): " setup_service

    if [[ "$setup_service" == "yes" ]]; then
        # Ensure we have the correct project path
        while [[ -z "$project_path" || ! -d "$project_path" ]]; do
            read -p "Enter the full path of your project (e.g., /home/youruser/myproject): " project_path
            if [[ ! -d "$project_path" ]]; then
                echo "❌ Invalid path. Please enter a valid project directory."
            fi
        done

        project_dir=$(basename "$project_path")
        read -p "Enter the port number for the service (e.g., 8001): " service_port
        read -p "How would you like to run the application? (1) Django runserver (2) Gunicorn [Enter 1 or 2]: " run_method

        service_name="${project_dir}-service"
        systemd_service_file="/etc/systemd/system/${service_name}.service"

        if [[ "$run_method" == "1" ]]; then
            # Running with Django's built-in development server
            app_command="python3 $project_path/manage.py runserver 0.0.0.0:$service_port"
        elif [[ "$run_method" == "2" ]]; then
            # Ensure Gunicorn is installed
            echo "🔹 Installing Gunicorn..."
            retry_command "pip3 install gunicorn"

            # Gunicorn command setup
            read -p "Enter the Python module (usually 'app' or 'project_name.wsgi'): " gunicorn_module
            app_command="gunicorn --workers 3 --bind 0.0.0.0:$service_port $gunicorn_module:application"
        else
            echo "❌ Invalid choice. Skipping systemd setup."
            exit 1
        fi

        echo "🔹 Setting up systemd service '$service_name'..."

        # Create systemd service file
        sudo tee "$systemd_service_file" > /dev/null <<EOL
[Unit]
Description=$service_name Django Service
After=network.target

[Service]
User=$USER
Group=$USER
WorkingDirectory=$project_path
ExecStart=$app_command
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOL

        # Reload systemd, start the service, and enable it
        retry_command "sudo systemctl daemon-reload"
        retry_command "sudo systemctl start $service_name"
        retry_command "sudo systemctl enable $service_name"

        log_progress "Setup Systemd Service"
        echo "✅ The project has been added as a systemd service named '$service_name' running on port $service_port."
    else
        echo "Skipping systemd service setup."
    fi
fi
echo "Server setup completed successfully. If any step failed, check '$ERROR_LOG'."