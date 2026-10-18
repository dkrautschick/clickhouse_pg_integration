# Demo 3 as code: Aiven for PostgreSQL + Aiven for ClickHouse (+ optional Kafka)
# and the native integrations between them. No Debezium connector JSON,
# no Kafka engine DDL: the platform wires it up.

resource "aiven_pg" "shop" {
  project      = var.project_name
  cloud_name   = var.cloud_name
  plan         = var.pg_plan
  service_name = var.pg_service_name
}

resource "aiven_clickhouse" "sidekick" {
  project      = var.project_name
  cloud_name   = var.cloud_name
  plan         = var.ch_plan
  service_name = var.ch_service_name
}

# PostgreSQL -> ClickHouse: ClickHouse gets a database named
# service_<pg service>_<database>_<schema> that mirrors the PostgreSQL tables.
resource "aiven_service_integration" "pg_to_ch" {
  project                  = var.project_name
  integration_type         = "clickhouse_postgresql"
  source_service_name      = aiven_pg.shop.service_name
  destination_service_name = aiven_clickhouse.sidekick.service_name

  clickhouse_postgresql_user_config {
    databases {
      database = var.pg_database
      schema   = var.pg_schema
    }
  }
}

# ---- optional: Kafka -> ClickHouse -------------------------------------------
resource "aiven_kafka" "events" {
  count        = var.with_kafka ? 1 : 0
  project      = var.project_name
  cloud_name   = var.cloud_name
  plan         = var.kafka_plan
  service_name = var.kafka_service_name
}

resource "aiven_kafka_topic" "beer_sales_events" {
  count        = var.with_kafka ? 1 : 0
  project      = var.project_name
  service_name = aiven_kafka.events[0].service_name
  topic_name   = var.kafka_topic
  partitions   = 3
  replication  = 2
}

# The topic becomes the ClickHouse table service_<kafka service>.beer_events
# (read AND write: INSERT produces messages, SELECT or a materialized view consumes them).
resource "aiven_service_integration" "kafka_to_ch" {
  count                    = var.with_kafka ? 1 : 0
  project                  = var.project_name
  integration_type         = "clickhouse_kafka"
  source_service_name      = aiven_kafka.events[0].service_name
  destination_service_name = aiven_clickhouse.sidekick.service_name

  clickhouse_kafka_user_config {
    tables {
      name              = "beer_events"
      group_name        = "clickhouse-sidekick"
      data_format       = "JSONEachRow"
      auto_offset_reset = "earliest"

      columns {
        name = "beer_name"
        type = "String"
      }
      columns {
        name = "country"
        type = "String"
      }
      columns {
        name = "liters"
        type = "Float32"
      }
      columns {
        name = "sold_at"
        type = "DateTime"
      }

      topics {
        name = var.kafka_topic
      }
    }
  }

  depends_on = [aiven_kafka_topic.beer_sales_events]
}
