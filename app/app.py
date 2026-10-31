"""
Sample web application for the K8s Secrets Audit Toolkit.

This app deliberately exposes secrets in multiple ways to demonstrate
how credentials leak through a Kubernetes operator lifecycle.

INTENTIONALLY INSECURE — for demonstration purposes only.
"""

import os
import logging
from flask import Flask, jsonify

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("webapp")

app = Flask(__name__)

db_config = {
    "host": os.environ.get("DB_HOST", "localhost"),
    "port": os.environ.get("DB_PORT", "5432"),
    "dbname": os.environ.get("DB_NAME", "appdb"),
    "user": os.environ.get("DB_USERNAME", "appuser"),
    "password": os.environ.get("DB_PASSWORD", ""),
}

logger.info(
    "Connecting to database: %s:%s/%s",
    db_config["host"], db_config["port"], db_config["dbname"]
)
logger.debug("DB connection config loaded for user: %s", db_config["user"])


@app.route("/health")
def health():
    return jsonify({"status": "healthy", "db_host": db_config["host"]})


@app.route("/")
def index():
    return jsonify({
        "app": "secrets-audit-demo",
        "message": (
            "This app deliberately exposes secrets in multiple ways "
            "for audit demonstration"
        ),
        "secret_exposure_points": [
            "Environment variables (DB_PASSWORD, API_KEY, JWT_SECRET)",
            "Mounted files at /etc/secrets/db/",
            "Application memory (db_config dict)",
            "Logs (connection string logged on startup)",
        ],
    })


@app.route("/db-check")
def db_check():
    try:
        import psycopg2
        conn = psycopg2.connect(**db_config)
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.close()
        conn.close()
        return jsonify({"db": "connected", "status": "ok"})
    except Exception as e:
        logger.error("Database connection failed: %s", e)
        return jsonify({"db": "failed", "error": str(e)}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
