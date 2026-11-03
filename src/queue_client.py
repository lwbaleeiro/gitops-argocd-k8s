import os
import json
import logging
import pika

logger = logging.getLogger("queue")

RABBITMQ_HOST = os.getenv("RABBITMQ_HOST", "rabbitmq")
RABBITMQ_PORT = int(os.getenv("RABBITMQ_PORT", "5672"))
RABBITMQ_USER = os.getenv("RABBITMQ_USER", "admin")
RABBITMQ_PASSWORD = os.getenv("RABBITMQ_PASSWORD", "admin123")
RABBITMQ_QUEUE = os.getenv("RABBITMQ_QUEUE", "cargas")


def get_rabbitmq_connection():
    credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
    parameters = pika.ConnectionParameters(
        host=RABBITMQ_HOST,
        port=RABBITMQ_PORT,
        credentials=credentials,
        connection_attempts=3,
        retry_delay=2,
    )
    return pika.BlockingConnection(parameters)


def publish_message(data: dict, queue_name: str = RABBITMQ_QUEUE):
    """Publica um payload em formato JSON na fila RabbitMQ."""
    connection = get_rabbitmq_connection()
    try:
        channel = connection.channel()
        channel.queue_declare(queue=queue_name, durable=True)
        message_body = json.dumps(data)
        channel.basic_publish(
            exchange="",
            routing_key=queue_name,
            body=message_body,
            properties=pika.BasicProperties(
                delivery_mode=pika.DeliveryMode.Persistent,
                content_type="application/json",
            ),
        )
        logger.info(f"Mensagem enviada para a fila '{queue_name}': {data.get('payload_id')}")
    finally:
        connection.close()


def check_rabbitmq_health(queue_name: str = RABBITMQ_QUEUE):
    """Checa a conexão com RabbitMQ e retorna status e total de mensagens pendentes na fila."""
    try:
        connection = get_rabbitmq_connection()
        channel = connection.channel()
        q = channel.queue_declare(queue=queue_name, durable=True, passive=False)
        message_count = q.method.message_count
        connection.close()
        return True, f"Conectado ({message_count} mensagens na fila)"
    except Exception as e:
        return False, str(e)

