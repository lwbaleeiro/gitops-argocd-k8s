import os
import json
import logging
import psycopg2
from psycopg2.extras import RealDictCursor

logger = logging.getLogger("db")

DB_HOST = os.getenv("DB_HOST", "postgres")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "demo")
DB_USER = os.getenv("DB_USER", "admin-user")
DB_PASSWORD = os.getenv("DB_PASSWORD", "senha-secreta-banco")


def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=5,
    )


def init_db():
    """Garante que a tabela cargas_processadas exista no banco de dados."""
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS cargas_processadas (
                    id SERIAL PRIMARY KEY,
                    payload_id VARCHAR(64) NOT NULL,
                    item_count INT NOT NULL,
                    payload_size_bytes INT NOT NULL,
                    items JSONB,
                    source VARCHAR(50) DEFAULT 'producer',
                    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
                );
                """
            )
        conn.commit()
        conn.close()
        logger.info("Banco de dados verificado com sucesso (tabela cargas_processadas pronta).")
    except Exception as e:
        logger.warning(f"Aviso ao inicializar tabela no DB: {e}")


def insert_carga(payload_id: str, item_count: int, payload_size_bytes: int, items: list, source: str = "worker"):
    """Insere um registro de carga processada no PostgreSQL."""
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO cargas_processadas (payload_id, item_count, payload_size_bytes, items, source)
                VALUES (%s, %s, %s, %s, %s)
                RETURNING id;
                """,
                (payload_id, item_count, payload_size_bytes, json.dumps(items), source),
            )
            inserted_id = cur.fetchone()[0]
        conn.commit()
        return inserted_id
    finally:
        conn.close()


def get_cargas(limit: int = 50):
    """Retorna as cargas processadas mais recentes."""
    conn = get_db_connection()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, payload_id, item_count, payload_size_bytes, items, source,
                       to_char(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at
                FROM cargas_processadas
                ORDER BY id DESC
                LIMIT %s;
                """,
                (limit,),
            )
            return cur.fetchall()
    finally:
        conn.close()


def check_db_health():
    """Checa se o PostgreSQL está acessível."""
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT 1;")
        conn.close()
        return True, "Conectado"
    except Exception as e:
        return False, str(e)

