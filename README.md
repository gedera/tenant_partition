# ActivePartition

**ActivePartition** es un framework de infraestructura para Ruby on Rails (7.1+) diseñado para simplificar y automatizar la gestión de **Particionamiento por Lista (List Partitioning)** nativo de PostgreSQL.

Específicamente construido para arquitecturas **Multi-tenant**, este framework resuelve la complejidad de:
1.  **Composite Primary Keys (CPK):** Configuración automática de claves compuestas (`id` + `partition_key`) requeridas por ActiveRecord para soportar particionamiento.
2.  **Orquestación Centralizada:** Una única interfaz para crear y eliminar particiones en **todos** los modelos de la aplicación simultáneamente.
3.  **Mantenimiento Zero-Downtime:** Migración atómica de datos "huérfanos" (que cayeron en la tabla `DEFAULT`) hacia sus particiones correctas sin perder servicio.

## 🚀 Características Principales

* **Fachada de Servicio:** API unificada (`ActivePartition.create!`, `destroy!`, `audit`, `cleanup!`) para gestionar el ciclo de vida completo de los tenants.
* **Introspección Inteligente:** Los modelos de negocio detectan automáticamente su configuración de infraestructura por convención (ej: `User` -> `Partition::User`).
* **Migration DSL:** Helper `create_partitioned_table` para definir tablas particionadas y sus tablas `DEFAULT` en una sola instrucción.
* **Seguridad Estricta:** Concern para controladores que valida Headers HTTP (`X-Tenant-ID`) para asegurar el contexto del tenant.
* **Observabilidad:** Instrumentación integrada con `ActiveSupport::Notifications`.

## 📋 Requisitos

* **Ruby:** >= 3.2
* **Ruby on Rails:** >= 7.1
* **PostgreSQL:** >= 13.0 (Requerido para `gen_random_uuid()` nativo)

## 📦 Instalación

Agrega esto a tu `Gemfile`:

```ruby
gem 'active_partition'
```

Luego ejecuta:

```bash
bundle install
```

## ⚙️ Configuración

Crea un inicializador en `config/initializers/active_partition.rb`. Es **obligatorio** definir la clave de partición.

```ruby
ActivePartition.configure do |config|
  # 1. La columna que discrimina los tenants (ej: :isp_id, :account_id, :tenant_id)
  config.partition_key = :isp_id

  # 2. El Header HTTP para la seguridad en controladores API
  config.header_name   = 'X-Tenant-ID'
end
```

## 🛠 Guía de Uso

### 1. Migraciones (Crear las Tablas)

Usa el helper `create_partitioned_table`. Este método deshabilita el ID automático simple y configura una **Primary Key Compuesta** (`[:id, :partition_key]`) necesaria para que PostgreSQL permita el particionamiento.

```ruby
class CreateConversations < ActiveRecord::Migration[7.1]
  def change
    create_partitioned_table :conversations do |t|
      # No definas t.primary_key. La gema crea (id, isp_id) automáticamente.
      t.string :topic
      t.timestamps
    end
  end
end
```

### 2. Capa de Infraestructura (Modelos Partition)

Define modelos que hereden de `ActivePartition::Base`. Estos modelos son responsables de las operaciones DDL (Create/Drop tables). Por convención, se recomienda usar el namespace `Partition::`.

```ruby
# app/models/partition/conversation.rb
module Partition
  class Conversation < ActivePartition::Base
    # Hereda la configuración global (:isp_id) automáticamente.
  end
end
```

### 3. Capa de Negocio (Modelos Rails)

En tus modelos estándar (`ApplicationRecord`), incluye el concern `Partitioned`.

**Magia de Introspección:**
Al incluir el concern, la gema busca automáticamente si existe un modelo de infraestructura asociado (ej: `Partition::Conversation`) y hereda su configuración.

```ruby
# app/models/conversation.rb
class Conversation < ApplicationRecord
  include ActivePartition::Concerns::Partitioned

  # ¡Listo! Rails ahora sabe que la Primary Key es [:id, :isp_id]
  # y aplica scopes automáticos.
end
```

### 4. Orquestación (Ciclo de Vida del Tenant)

Ya no necesitas crear particiones tabla por tabla. Usa la **Fachada** `ActivePartition` para gestionar la infraestructura de un tenant en **todos** los modelos registrados simultáneamente.

**Crear un nuevo Tenant (Provisioning):**
Ideal para usar en tu `RegistrationService` o `AfterCommit` de la creación del tenant.

```ruby
# En tu Service Object o Controller de registro
def create_tenant
  isp = Isp.create!(params)

  # Busca TODOS los modelos particionados y crea las tablas físicas para este ID.
  # Es idempotente: si alguna ya existe, la salta sin error.
  ActivePartition.create!(isp.id)
end
```

**Eliminar un Tenant (Deprovisioning):**

```ruby
# Esta operación realiza DETACH + DROP de las tablas físicas.
# ¡Es destructiva e irreversible!
ActivePartition.destroy!(old_isp.id)
```

### 5. Seguridad en Controladores

Protege tus API endpoints asegurando que siempre reciban el ID del tenant.

```ruby
class ApiController < ActionController::API
  include ActivePartition::Concerns::Controller

  # Valida que el request traiga el header 'X-Tenant-ID'.
  # Devuelve 400 Bad Request si falta.
  before_action :require_partition_key!

  def index
    # current_partition_id contiene el valor seguro del Header
    @chats = Conversation.for_partition(current_partition_id).all
    render json: @chats
  end
end
```

## 🛡 Mantenimiento y Recuperación

ActivePartition maneja el escenario de "Race Condition" donde llegan datos *antes* de que la partición exista. Esos datos caen automáticamente en la tabla `_default`.

### Auditoría

Verifica si tienes datos "fugados" en las tablas default:

```ruby
# Desde consola Rails
report = ActivePartition.audit
# => { "Partition::Conversation" => 14, "Partition::Message" => 0 }
```

O vía Rake task:
```bash
bundle exec rails active_partition:audit
```

### Limpieza (Cleanup)

Mueve los datos huérfanos a sus particiones correspondientes de forma atómica y segura.

```ruby
# Ruby API (Ideal para Jobs nocturnos)
ActivePartition.cleanup!
```

O vía Rake task:
```bash
bundle exec rails active_partition:cleanup
```

## 📊 Observabilidad

Puedes suscribirte a los eventos para enviar métricas a tu sistema de monitoreo (Datadog, Prometheus, NewRelic).

```ruby
# config/initializers/notifications.rb
ActiveSupport::Notifications.subscribe(/active_partition/) do |name, start, finish, id, payload|
  duration = (finish - start) * 1000

  case name
  when "create.active_partition"
    Rails.logger.info "📦 Partición creada: #{payload[:table]} para #{payload[:value]}"
  when "populate.active_partition"
    Rails.logger.info "🧹 Limpieza: #{payload[:count]} registros movidos en #{duration.round(2)}ms"
  end
end
```

## 📄 Licencia

Este proyecto está disponible como código abierto bajo los términos de la [Licencia MIT](https://opensource.org/licenses/MIT).
