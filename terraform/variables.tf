variable "aiven_api_token" {
  description = "Aiven API token. Leave null to use the AIVEN_TOKEN environment variable."
  type        = string
  default     = null
  sensitive   = true
}

variable "project_name" {
  description = "Name of your existing Aiven project."
  type        = string
}

variable "cloud_name" {
  description = "Cloud and region, see `avn cloud list`."
  type        = string
  default     = "google-europe-west1"
}

variable "pg_service_name" {
  type    = string
  default = "shop-pg"
}

variable "ch_service_name" {
  type    = string
  default = "beer-clickhouse"
}

variable "kafka_service_name" {
  type    = string
  default = "events-kafka"
}

variable "pg_plan" {
  type    = string
  default = "startup-4"
}

variable "ch_plan" {
  type    = string
  default = "startup-16"
}

variable "kafka_plan" {
  type    = string
  default = "startup-2"
}

variable "pg_database" {
  description = "PostgreSQL database exposed to ClickHouse."
  type        = string
  default     = "defaultdb"
}

variable "pg_schema" {
  description = "PostgreSQL schema exposed to ClickHouse."
  type        = string
  default     = "public"
}

variable "with_kafka" {
  description = "Also create Aiven for Apache Kafka and the clickhouse_kafka integration."
  type        = bool
  default     = false
}

variable "kafka_topic" {
  type    = string
  default = "beer_sales_events"
}
