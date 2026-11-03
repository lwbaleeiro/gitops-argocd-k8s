import json
import logging
import os
import signal
import sys
import time
import pika
import db

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [Worker] %(message)s"
)
logger = logging.getLogger("worker")

RABBITMQ_HOST = os.getenv("RABBITMQ_HOST", "rabbitmq")
RABBITMQ_PORT = int(os.getenv("RABBITMQ_PORT", "5672"))
RABBITMQ_USER = os.getenv("RABBITMQ_USER", "admin")
RABBITMQ_PASSWORD = os.getenv("RABBITMQ_PASSWORD", "admin123")
RABBITMQ_QUEUE = os.getenv("RABBITMQ_QUEUE", "cargas")

running = True


def signal_handler(sig, frame):
    global running
    logger.info("Sinal de término recebido. Encerrando worker suavemente...")
    running = False


signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)


def process_message(ch, method, properties, body):
    try:
        data = json.loads(body.decode("utf-8"))
        payload_id = data.get("payload_id", "desconhecido")
        item_count = data.get("item_count", 0)
        payload_size_bytes = data.get("payload_size_bytes", len(body))
        items = data.get("items", [])
        source = data.get("source", "producer")

        logger.info(f"📥 Recebida carga '{payload_id}' com {item_count} itens ({payload_size_bytes} bytes) de '{source}'")

        # Salva no PostgreSQL
        db_id = db.insert_carga(
            payload_id=payload_id,
            item_count=item_count,
            payload_size_bytes=payload_size_bytes,
            items=items,
            source=source,
        )

        logger.info(f"💾 Carga '{payload_id}' gravada com sucesso no PostgreSQL! (Registro ID: {db_id})")

        # Confirma consumo da mensagem no RabbitMQ
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except Exception as e:
        logger.error(f"❌ Erro ao processar mensagem: {e}", exc_info=True)
        # Em caso de erro, re-enfileira ou descarta dependendo do caso (aqui faz nack com requeue=False para não travar loop)
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=False)


def run_worker():
    global running
    logger.info("Iniciando Worker Consumer...")

    # Garante que o banco de dados e a tabela estejam prontos
    db.init_db()

    credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
    parameters = pika.ConnectionParameters(
        host=RABBITMQ_HOST,
        port=RABBITMQ_PORT,
        credentials=credentials,
        heartbeat=600,
        blocked_connection_timeout=300,
    )

    while running:
        try:
            logger.info(f"Conectando ao RabbitMQ em {RABBITMQ_HOST}:{RABBITMQ_PORT}...")
            connection = pika.BlockingConnection(parameters)
            channel = connection.channel()

            # Assegura a existência da fila
            channel.queue_declare(queue=RABBITMQ_QUEUE, durable=True)
            # Fair dispatch: entrega 1 mensagem por vez para o worker
            channel.basic_qos(prefetch_count=1)

            channel.basic_consume(
                queue=RABBITMQ_QUEUE,
                on_message_callback=process_message,
                auto_ack=False,
            )

            logger.info(f" Worker conectado e pronto! Aguardando cargas na fila '{RABBITMQ_QUEUE}'...")

            while running and channel.is_open:
                connection.process_data_events(time_limit=1)

            if connection.is_open:
                connection.close()

        except pika.exceptions.AMQPConnectionError as e:
            logger.warning(f"RabbitMQ indisponível ({e}). Tentando novamente em 5 segundos...")
            time.sleep(5)
        except Exception as e:
            logger.error(f"Erro inesperado no worker: {e}. Reiniciando conexão em 5 segundos...")
            time.sleep(5)

    logger.info("Worker finalizado com sucesso.")


if __name__ == "__main__":
    run_worker()

