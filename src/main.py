import logging
import os
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, FileResponse
from pydantic import BaseModel, Field

import db
from queue_client import check_rabbitmq_health
from producer import send_carga

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [API] %(message)s"
)
logger = logging.getLogger("api")

app = FastAPI(title="GitOps Demo App API", version="2.0.0")

ENVIRONMENT = os.getenv("ENVIRONMENT", "dev")


class CargaRequest(BaseModel):
    item_count: int = Field(default=10, ge=1, le=5000, description="Quantidade de itens na carga")
    item_size_bytes: int = Field(default=64, ge=0, le=10240, description="Tamanho em bytes por item")
    source: str = Field(default="web-ui", description="Identificador da origem")


@app.on_event("startup")
def startup_event():
    logger.info(f"Iniciando API no ambiente: {ENVIRONMENT}")
    db.init_db()


@app.get("/", response_class=HTMLResponse)
def get_root():
    """Retorna o frontend da aplicação."""
    html_path = os.path.join(os.path.dirname(__file__), "index.html")
    if os.path.exists(html_path):
        return FileResponse(html_path)
    return "<h1>GitOps Demo App</h1><p>index.html não encontrado.</p>"


@app.get("/api/status")
def get_status():
    """Retorna a saúde dos serviços: Web API, PostgreSQL e RabbitMQ."""
    db_ok, db_msg = db.check_db_health()
    rmq_ok, rmq_msg = check_rabbitmq_health()

    return {
        "environment": ENVIRONMENT,
        "services": {
            "api": {"status": "ok", "message": "Operacional"},
            "database": {"status": "ok" if db_ok else "error", "message": db_msg},
            "rabbitmq": {"status": "ok" if rmq_ok else "error", "message": rmq_msg},
        },
    }


@app.get("/api/cargas")
def list_cargas(limit: int = 50):
    """Retorna as cargas processadas e gravadas no banco de dados."""
    try:
        cargas = db.get_cargas(limit=limit)
        return {"total": len(cargas), "cargas": cargas}
    except Exception as e:
        logger.error(f"Erro ao consultar banco de dados: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/payloads")
def trigger_carga(req: CargaRequest):
    """Gera uma carga com as especificações solicitadas e publica no RabbitMQ."""
    try:
        payload = send_carga(
            item_count=req.item_count,
            item_size_bytes=req.item_size_bytes,
            source=req.source,
        )
        return {
            "message": "Carga enfileirada no RabbitMQ com sucesso!",
            "payload_id": payload["payload_id"],
            "item_count": payload["item_count"],
            "payload_size_bytes": payload["payload_size_bytes"],
        }
    except Exception as e:
        logger.error(f"Erro ao publicar carga no RabbitMQ: {e}")
        raise HTTPException(status_code=500, detail=f"Erro ao enviar carga: {e}")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=80, reload=False)

