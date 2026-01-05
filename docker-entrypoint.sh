#!/bin/bash
set -e

# Function to generate configuration only if env vars are present
if [ ! -f /var/www/html/pp-config.php ] && [ ! -z "$DB_HOST" ]; then
    echo "Filesystem config not found, generating from environment variables..."
    
    DB_PORT=${DB_PORT:-3306}
    DB_PREFIX=${DB_PREFIX:-pp_}
    DB_MODE=${DB_MODE:-live}
    PASSWORD_RESET=${PASSWORD_RESET:-off}

    cat > /var/www/html/pp-config.php <<EOF
<?php
    \$db_host = '$DB_HOST';
    \$db_user = '$DB_USER';
    \$db_pass = '$DB_PASSWORD';
    \$db_name = '$DB_NAME';
    \$db_prefix = '$DB_PREFIX';
    \$mode = '$DB_MODE';
    \$password_reset = '$PASSWORD_RESET';
?>
EOF
    echo "Config generated."

    # Create a temporary PHP script to check DB and install if needed
    cat > /tmp/install_db.php <<'EOF'
<?php
    require '/var/www/html/pp-config.php';

    // Retry loop for DB connection
    $max_retries = 30;
    $attempt = 0;
    $connected = false;
    $conn = null;
    
    // Enable exception reporting for mysqli to catch connection errors
    mysqli_report(MYSQLI_REPORT_STRICT | MYSQLI_REPORT_ERROR);

    while ($attempt < $max_retries) {
        try {
            // Suppress warnings to avoid spamming logs on transient errors
            $conn = new mysqli($db_host, $db_user, $db_pass, $db_name);
            $connected = true;
            break;
        } catch (Exception $e) {
            $attempt++;
            fwrite(STDERR, "MySQL Connection Attempt $attempt/$max_retries Failed: " . $e->getMessage() . "\n");
            // Wait with Jitter
            sleep(2);
        }
    }

    if (!$connected) {
        fwrite(STDERR, "Fatal: Could not connect to database after $max_retries attempts.\n");
        exit(1);
    }

    // Check if tables exist (check for settings table)
    $check = $conn->query("SHOW TABLES LIKE '{$db_prefix}settings'");
    if ($check->num_rows > 0) {
        echo "Database already initialized. Skipping installation.\n";
        exit(0);
    }

    echo "Database empty. Starting headless installation...\n";

    // 1. Import database.sql
    $sql = file_get_contents('/opt/piprapay/database.sql');
    if (!$sql) {
        fwrite(STDERR, "Error: database.sql not found.\n");
        exit(1);
    }
    $sql = str_replace("__PREFIX__", $db_prefix, $sql);
    
    // Execute multi_query for schema
    if ($conn->multi_query($sql)) {
        do {
            $conn->store_result();
        } while ($conn->more_results() && $conn->next_result());
    } else {
        fwrite(STDERR, "Error importing database.sql: " . $conn->error . "\n");
        exit(1);
    }
    echo "Schema imported.\n";

    // 2. Import currency.sql
    $sql = file_get_contents('/opt/piprapay/currency.sql');
    if ($sql) {
        $sql = str_replace("INSERT INTO `currency`", "INSERT INTO `{$db_prefix}currency`", $sql);
        if ($conn->multi_query($sql)) {
            do {
                $conn->store_result();
            } while ($conn->more_results() && $conn->next_result());
        } else {
             fwrite(STDERR, "Error importing currency.sql: " . $conn->error . "\n");
        }
        echo "Currencies imported.\n";
    }

    // 3. Import timezone.sql
    $sql = file_get_contents('/opt/piprapay/timezone.sql');
    if ($sql) {
        $sql = str_replace("INSERT INTO `timezone`", "INSERT INTO `{$db_prefix}timezone`", $sql);
        if ($conn->multi_query($sql)) {
             do {
                $conn->store_result();
            } while ($conn->more_results() && $conn->next_result());
        } else {
             fwrite(STDERR, "Error importing timezone.sql: " . $conn->error . "\n");
        }
        echo "Timezones imported.\n";
    }

    // 4. Create Admin User
    $adminName = getenv('ADMIN_NAME') ?: 'Administrator';
    $adminEmail = getenv('ADMIN_EMAIL') ?: 'admin@example.com';
    $adminUser = getenv('ADMIN_USER') ?: 'admin';
    $adminPass = getenv('ADMIN_PASSWORD') ?: 'password';

    $hashedPass = password_hash($adminPass, PASSWORD_BCRYPT);
    $stmt = $conn->prepare("INSERT INTO `{$db_prefix}admins` (name, email, username, password) VALUES (?, ?, ?, ?)");
    $stmt->bind_param("ssss", $adminName, $adminEmail, $adminUser, $hashedPass);
    
    if ($stmt->execute()) {
        echo "Admin user created: $adminUser / $adminEmail\n";
    } else {
        fwrite(STDERR, "Error creating admin: " . $stmt->error . "\n");
        exit(1);
    }

    // 5. Insert Settings
    $conn->query("INSERT INTO `{$db_prefix}settings` (site_name) VALUES ('PipraPay')");
    echo "Settings initialized.\n";

    $conn->close();
?>
EOF

    # Run the installation script
    echo "Running installation script..."
    php /tmp/install_db.php
    RESULT=$?
    rm /tmp/install_db.php
    
    if [ $RESULT -eq 0 ]; then
        echo "Installation successful. Cleaning up SQL files..."
        rm -f /opt/piprapay/*.sql
    fi
fi

# Execute the CMD
exec "$@"
