# ActivePartition

**ActivePartition** es un framework de infraestructura para Ruby on Rails que simplifica la gestión de particionamiento nativo en PostgreSQL (List Partitioning).

Diseñado específicamente para arquitecturas **Multi-tenant** y microservicios, permite manejar el ciclo de vida de las particiones (creación, migración de datos y eliminación) utilizando convenciones familiares al estilo de ActiveRecord.

## 🚀 Características

* **Agnóstico al Dominio**: Configura tu propia clave de partición (`isp_id`, `account_id`, etc.) globalmente o por modelo.
* **Migration Helpers**: DSL nativo para crear tablas particionadas y sus tablas `DEFAULT` automáticamente.
* **Developer Experience (DX)**: Concerns integrados para asegurar controladores y filtrar modelos automáticamente.
* **Strict Security Strategy**: Validación automática de Headers HTTP para identificar tenants.
* **Zero-Downtime Data Move**: Mueve registros "huérfanos" de la tabla default a su partición correcta de forma atómica.
* **Observabilidad**: Instrumentación integrada con `ActiveSupport::Notifications`.

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
  # 1. Columna de base de datos que discrimina tus particiones (Global).
  config.partition_key = :isp_id

  # 2. Nombre exacto del Header HTTP que traerá el ID del tenant.
  # La estrategia de seguridad por defecto del controlador es ESTRICTA: solo leerá de este header.
  config.header_name = 'X-Tenant-ID'
end
```

## 🛠 Uso

### 1. Migraciones

ActivePartition extiende las migraciones de Rails. Usa `create_partitioned_table`.

**Uso Estándar (Usa la clave global):**
```ruby
class CreateMessages < ActiveRecord::Migration[7.0]
  def change
    create_partitioned_table :messages do |t|
      t.uuid :chat_id, null: false
      t.jsonb :payload
      t.timestamps
    end
  end
end
```

**Uso Avanzado (Clave personalizada):**
```ruby
class CreateLogs < ActiveRecord::Migration[7.0]
  def change
    # Sobrescribe la clave global solo para esta tabla
    create_partitioned_table :system_logs, partition_key: :region_code do |t|
      t.text :message
    end
  end
end
```

### 2. Modelos de Infraestructura

Crea modelos que hereden de `ActivePartition::Base` para gestionar la creación/eliminación de particiones físicas.

**Modelo Estándar:**
```ruby
# app/models/partition/message.rb
module Partition
  class Message < ActivePartition::Base
    # Usa :isp_id (global) e infiere nombres de tabla
  end
end
```

### 3. Personalización Avanzada (Convenciones)

Si tienes una base de datos legacy o no sigues las convenciones de Rails, puedes sobrescribir manualmente los nombres de las tablas y prefijos.

```ruby
# app/models/partition/legacy_data.rb
module Partition
  class LegacyData < ActivePartition::Base
    # Sobrescribir la clave de partición
    self.partition_key = :client_code

    # Sobrescribir el nombre de la tabla padre
    self.parent_table = "tbl_legacy_data"

    # Sobrescribir el prefijo de las particiones hijas
    # Las tablas se crearán como: "data_partition_CLI001", "data_partition_CLI002"...
    self.prefix = "data_partition"

    # Sobrescribir la tabla default
    self.default_table = "tbl_legacy_data_fallback"
  end
end
```

### 4. Integración en Modelos de Negocio (Concerns)

Para tus modelos normales (`ApplicationRecord`), incluye el concern `Partitioned` para agregar scopes dinámicos.

```ruby
class Message < ApplicationRecord
  include ActivePartition::Concerns::Partitioned
end

# Uso automático del filtro según configuración:
Message.for_partition("uuid-tenant-123").all
```

### 5. Seguridad en Controladores (Concerns)

Protege tus endpoints API asegurando que siempre reciban el ID del tenant.

#### Estrategia por Defecto (Headers)
La gema buscará automáticamente el header configurado (`X-Tenant-ID`).

```ruby
class ApiController < ActionController::API
  include ActivePartition::Concerns::Controller

  # Valida presencia del ID. Devuelve 400 Bad Request si falta.
  before_action :require_partition_key!

  def index
    # 'current_partition_id' devuelve el valor del Header
    @messages = Message.for_partition(current_partition_id).all
    render json: @messages
  end
end
```

#### Personalización de la Estrategia (Override)
Si tu API no es REST tradicional o necesitas extraer el ID de otra fuente (JWT, Subdominios, Cookies), simplemente sobrescribe el método `current_partition_id`.

```ruby
class GraphqlController < ApplicationController
  include ActivePartition::Concerns::Controller

  # El filtro 'require_partition_key!' usará tu método personalizado
  before_action :require_partition_key!

  private

  # Sobrescribimos la lógica por defecto de la gema
  def current_partition_id
    # Ejemplo: Extraer desde un token JWT decodificado en lugar de headers crudos
    @current_partition_id ||= current_user_token.payload['tenant_uuid']
  end
end
```

### 6. Gestión de Particiones (Infraestructura)

Puedes crear, buscar y eliminar particiones físicamente:

```ruby
tenant_uuid = "c6920194-b15e-41e0-b0c0-1f2f0a8c2d3e"

# Crear tabla física
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

* `bundle exec rails active_partition:audit` : Busca datos "fugados" en tablas DEFAULT.
* `bundle exec rails active_partition:cleanup` : Mueve datos huérfanos a sus particiones correctas.

## 📊 Observabilidad

Suscríbete a los eventos para enviar métricas a tu sistema de monitoreo.

```ruby
# config/initializers/active_partition_notifications.rb
ActiveSupport::Notifications.subscribe(/active_partition/) do |name, start, finish, id, payload|
  duration = (finish - start) * 1000

  case name
  when "create.active_partition"
    Rails.logger.info "Partición creada: #{payload[:table]} (Key: #{payload[:partition_key]}) -> #{payload[:value]}"
  when "populate.active_partition"
    Rails.logger.info "Migrados #{payload[:count]} registros en #{duration.round(2)}ms"
  end
end
```

## 📄 Licencia

La gema está disponible como código abierto bajo los términos de la [Licencia MIT](https://opensource.org/licenses/MIT).
