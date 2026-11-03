CREATE TABLE IF NOT EXISTS cargas_processadas (
    id SERIAL PRIMARY KEY,
    payload_id VARCHAR(64) NOT NULL,
    item_count INT NOT NULL,
    payload_size_bytes INT NOT NULL,
    items JSONB,
    source VARCHAR(50) DEFAULT 'producer',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

