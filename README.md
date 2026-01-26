# ActivePartition

**ActivePartition** es un framework de infraestructura para Ruby on Rails que simplifica la gestión de particionamiento nativo en PostgreSQL (List Partitioning).

Diseñado específicamente para arquitecturas **Multi-tenant** y microservicios, permite manejar el ciclo de vida de las particiones (creación, migración de datos y eliminación) utilizando convenciones familiares al estilo de ActiveRecord.

## 🚀 Características

* **Agnóstico al Dominio**: Configura tu propia clave de partición (`isp_id`, `account_id`, `tenant_id`, etc.).
* **Migration Helpers**: DSL nativo para crear tablas particionadas y sus tablas `DEFAULT` automáticamente.
* **ActivePartition::Base**: Modelos dedicados a la infraestructura que separan la lógica de negocio de la lógica de base de datos.
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

Debes configurar la clave que tu sistema usará para separar los tenants (la columna de partición). Crea un inicializador en `config/initializers/active_partition.rb`:

```ruby
ActivePartition.configure do |config|
  # Define la columna que discrimina tus particiones.
  # Ejemplos comunes: :isp_id, :account_id, :client_id
  config.partition_key = :isp_id
end
```

> **Nota:** Si no configuras el `partition_key`, la gema impedirá que la aplicación arranque para evitar inconsistencias de datos.

## 🛠 Uso

### 1. Migraciones

ActivePartition extiende las migraciones de Rails. Usa `create_partitioned_table` en lugar de `create_table`. La gema inyectará automáticamente la columna de partición y creará la tabla `_default` necesaria.

```ruby
class CreateMessages < ActiveRecord::Migration[7.0]
  def change
    # NO necesitas declarar t.string :isp_id, la gema lo hace por ti.
    create_partitioned_table :messages do |t|
      t.uuid :chat_id, null: false
      t.jsonb :payload, default: {}
      t.string :state, default: 'pending'
      
      t.timestamps
    end
    
    # Esto genera en SQL:
    # 1. CREATE TABLE messages (..., isp_id string) PARTITION BY LIST (isp_id);
    # 2. CREATE TABLE messages_default PARTITION OF messages DEFAULT;
  end
end
```

### 2. Modelos de Infraestructura

Crea modelos que hereden de `ActivePartition::Base`. Estos modelos representan la **partición física**, no el dato de negocio.

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

### 3. Gestión de Particiones

Puedes crear, buscar y eliminar particiones utilizando una API orientada a objetos.

```ruby
tenant_uuid = "c6920194-b15e-41e0-b0c0-1f2f0a8c2d3e"

# 1. Crear una partición física para un Tenant
partition = Partition::Message.create(tenant_uuid)
# => Crea la tabla "messages_isp_c6920194_b15e_..."

# 2. Verificar existencia
Partition::Message.exists?(tenant_uuid) # => true

# 3. Eliminar partición (Safe Drop: Detach + Drop)
partition.destroy
```

## 🛡 Mantenimiento y Resiliencia

### Recuperación de Datos Huérfanos
Si por alguna condición de carrera (race condition) llegaron datos antes de que se creara la partición, estos caerán en la tabla `_default`. Puedes moverlos a su lugar correcto fácilmente:

```ruby
partition = Partition::Message.find(tenant_uuid)

# Mueve datos atómicamente de default a la partición del tenant
partition.populate_from_default
```

### Tareas Rake (Ops)
La gema incluye tareas para auditar la salud de tu base de datos:

* **Auditoría**: Verifica si hay datos en las tablas `DEFAULT` (lo cual no debería ocurrir en un flujo ideal).
    ```bash
    bundle exec rails active_partition:audit
    ```

* **Limpieza Automática**: Detecta datos huérfanos y los mueve a sus particiones correspondientes.
    ```bash
    bundle exec rails active_partition:cleanup
    ```

## 📊 Observabilidad

Puedes suscribirte a los eventos de la gema para enviar métricas a tu sistema de monitoreo (Datadog, NewRelic, Logs).

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

## 🤝 Contribuyendo

Los reportes de bugs y pull requests son bienvenidos en GitHub en [https://github.com/gedera/active_partition](https://github.com/gedera/active_partition).

## 📄 Licencia

La gema está disponible como código abierto bajo los términos de la [Licencia MIT](https://opensource.org/licenses/MIT).
