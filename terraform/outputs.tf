output "pg_service" {
  value = aiven_pg.shop.service_name
}

output "clickhouse_service" {
  value = aiven_clickhouse.sidekick.service_name
}

output "clickhouse_host" {
  value = aiven_clickhouse.sidekick.service_host
}

# Database that the clickhouse_postgresql integration creates inside ClickHouse
output "clickhouse_pg_database" {
  value = "service_${aiven_pg.shop.service_name}_${var.pg_database}_${var.pg_schema}"
}

output "pg_service_uri" {
  value     = aiven_pg.shop.service_uri
  sensitive = true
}
