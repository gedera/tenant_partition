# ActivePartition

**ActivePartition** es un framework de infraestructura para Ruby on Rails que simplifica la gestión de particionamiento nativo en PostgreSQL (List Partitioning).

Diseñado específicamente para arquitecturas **Multi-tenant** y microservicios, permite manejar el ciclo de vida de las particiones (creación, migración de datos y eliminación) utilizando convenciones familiares al estilo de ActiveRecord.

## 🚀 Características

* **Agnóstico al Dominio**: Configura tu propia clave de partición (`isp_id`, `account_id`, `tenant_id`, etc.).
* **Migration Helpers**: DSL nativo para crear tablas particionadas y sus tablas `DEFAULT` automáticamente.
* **Developer Experience (DX)**: Concerns integrados para asegurar controladores y filtrar modelos automáticamente.
* **Zero-Downtime Data Move**: Mueve registros "huérfanos" de la tabla default a su partición correcta de forma atómica.
* **Observabilidad**: Instrumentación integrada con `ActiveSupport::Notifications`.
* **Safety Guard**: Validaciones automáticas de versión de PostgreSQL (10+) y configuración.

## 📋 Requisitos

* Ruby >= 3.2
* Ruby on Rails >= 6.0
* PostgreSQL >= 10.0 (Se recomienda 12+ para mejor performance)

## 📦 Instalación

Agrega esta línea al Gemfile de tu aplicación:

```ruby
gem 'active_partition'
```

Y luego ejecuta:

```bash
bundle install
```

## ⚙️ Configuración

Crea un inicializador en `config/initializers/active_partition.rb`. Es vital configurar tanto la clave de la base de datos como el Header HTTP esperado para la seguridad de la API.

```ruby
ActivePartition.configure do |config|
  # 1. Columna de base de datos que discrimina tus particiones.
  config.partition_key = :isp_id

  # 2. Nombre exacto del Header HTTP que traerá el ID del tenant.
  # La estrategia de seguridad del controlador es ESTRICTA: solo leerá de este header.
  config.header_name = 'X-Tenant-ID'
end
```

## 🛠 Uso

### 1. Migraciones

ActivePartition extiende las migraciones de Rails. Usa `create_partitioned_table` para que la gema inyecte automáticamente la columna de partición y cree la tabla `_default` necesaria.

```ruby
class CreateMessages < ActiveRecord::Migration[7.0]
  def change
    create_partitioned_table :messages do |t|
      t.uuid :chat_id, null: false
      t.jsonb :payload, default: {}
      t.string :state, default: 'pending'

      t.timestamps
    end
    # SQL Generado:
    # CREATE TABLE messages (..., isp_id string) PARTITION BY LIST (isp_id);
    # CREATE TABLE messages_default PARTITION OF messages DEFAULT;
  end
end
```

### 2. Modelos de Infraestructura

Crea modelos que hereden de `ActivePartition::Base`. Estos modelos representan la **partición física** y se usan para operaciones de mantenimiento (crear/borrar tablas), no para lógica de negocio.

```ruby
# app/models/partition/message.rb
module Partition
  class Message < ActivePartition::Base
    # Se infiere automáticamente:
    # parent_table: 'messages'
    # prefix: 'messages_isp'
  end
end
```

### 3. Integración en Modelos de Negocio (Concerns)

Para tus modelos normales (`ApplicationRecord`), incluye el concern `Partitioned`. Esto agrega scopes dinámicos para facilitar las consultas.

```ruby
class Message < ApplicationRecord
  include ActivePartition::Concerns::Partitioned
end

# Uso:
# Filtra automáticamente usando la columna configurada (ej: isp_id)
Message.for_partition("uuid-tenant-123").where(state: "sent")
```

### 4. Seguridad en Controladores (Concerns)

Protege tus endpoints API asegurando que siempre reciban el ID del tenant en el header configurado.

```ruby
class ApiController < ActionController::API
  include ActivePartition::Concerns::Controller

  # Bloquea la petición con 400 Bad Request si falta el header 'X-Tenant-ID'
  before_action :require_partition_key!

  def index
    # 'current_partition_id' lee directamente el valor del Header
    @messages = Message.for_partition(current_partition_id).all
    render json: @messages
  end
end
```

### 5. Gestión de Particiones (Infraestructura)

Puedes crear, buscar y eliminar particiones físicamente:

```ruby
tenant_uuid = "c6920194-b15e-41e0-b0c0-1f2f0a8c2d3e"

# Crear tabla física para un nuevo tenant
Partition::Message.create(tenant_uuid)

# Verificar existencia
Partition::Message.exists?(tenant_uuid) # => true

# Eliminar partición (Safe Drop: Detach + Drop)
Partition::Message.find(tenant_uuid).destroy
```

## 🛡 Mantenimiento y Resiliencia

### Recuperación de Datos Huérfanos
Si por alguna condición de carrera llegaron datos antes de que se creara la partición, estos caerán en la tabla `_default`. Puedes moverlos a su lugar correcto atómicamente:

```ruby
partition = Partition::Message.find(tenant_uuid)
partition.populate_from_default
```

### Tareas Rake (Ops)
Herramientas para auditar la salud de tu base de datos:

* **Auditoría**: Verifica si hay datos "fugados" en las tablas `DEFAULT`.
    ```bash
    bundle exec rails active_partition:audit
    ```

* **Limpieza Automática**: Detecta datos huérfanos y los mueve a sus particiones correspondientes.
    ```bash
    bundle exec rails active_partition:cleanup
    ```

## 📊 Observabilidad

Suscríbete a los eventos para enviar métricas a tu sistema de monitoreo (Datadog, NewRelic, Logs).

```ruby
# config/initializers/active_partition_notifications.rb
ActiveSupport::Notifications.subscribe(/active_partition/) do |name, start, finish, id, payload|
  duration = (finish - start) * 1000

  case name
  when "create.active_partition"
    Rails.logger.info "[Infrastructure] Partición creada: #{payload[:table]} -> #{payload[:value]}"
  when "populate.active_partition"
    Rails.logger.info "[Recovery] Migrados #{payload[:count]} registros en #{duration.round(2)}ms"
  end
end
```

## 📄 Licencia

La gema está disponible como código abierto bajo los términos de la [Licencia MIT](https://opensource.org/licenses/MIT).
