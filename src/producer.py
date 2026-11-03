import argparse
import json
import logging
import random
import string
import time
import uuid
from queue_client import publish_message

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("producer")


def generate_random_data(size_bytes: int) -> str:
    """Gera uma string aleatória com o tamanho aproximado especificado."""
    if size_bytes <= 0:
        return ""
    letters = string.ascii_letters + string.digits
    return "".join(random.choices(letters, k=size_bytes))


def create_payload(item_count: int = 10, item_size_bytes: int = 64, source: str = "producer") -> dict:
    """Cria e estrutura o payload com a quantidade de itens e tamanho configurados."""
    payload_id = f"carga-{int(time.time())}-{uuid.uuid4().hex[:6]}"
    items = []

    for i in range(1, item_count + 1):
        items.append({
            "item_index": i,
            "sku": f"ITEM-{random.randint(1000, 9999)}",
            "value": round(random.uniform(10.0, 500.0), 2),
            "data": generate_random_data(item_size_bytes),
        })

    raw_json = json.dumps(items)
    payload_size_bytes = len(raw_json.encode("utf-8"))

    payload = {
        "payload_id": payload_id,
        "item_count": item_count,
        "payload_size_bytes": payload_size_bytes,
        "source": source,
        "items": items,
        "timestamp": time.time(),
    }
    return payload


def send_carga(item_count: int = 10, item_size_bytes: int = 64, source: str = "producer") -> dict:
    """Gera a carga e publica no RabbitMQ."""
    payload = create_payload(item_count=item_count, item_size_bytes=item_size_bytes, source=source)
    publish_message(payload)
    logger.info(
        f"🚀 Carga enviada! ID: {payload['payload_id']} | Itens: {payload['item_count']} | Tamanho: {payload['payload_size_bytes']} bytes"
    )
    return payload


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Gerador de Cargas para RabbitMQ")
    parser.add_argument("--items", type=int, default=10, help="Quantidade de itens na carga (default: 10)")
    parser.add_argument("--size", type=int, default=64, help="Tamanho aproximado dos dados por item em bytes (default: 64)")
    parser.add_argument("--source", type=str, default="cli", help="Origem da carga (default: cli)")
    parser.add_argument("--count", type=int, default=1, help="Quantidade de cargas a enviar (default: 1)")
    parser.add_argument("--interval", type=float, default=1.0, help="Intervalo em segundos entre cargas (default: 1.0)")

    args = parser.parse_args()

    for n in range(args.count):
        send_carga(item_count=args.items, item_size_bytes=args.size, source=args.source)
        if n < args.count - 1:
            time.sleep(args.interval)

