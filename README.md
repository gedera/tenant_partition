# TenantPartition

**TenantPartition** es una solución robusta y "Rails-native" para implementar **Particionamiento Declarativo (List Partitioning)** de PostgreSQL en aplicaciones Ruby on Rails.

A diferencia de otras soluciones que dependen de esquemas (schemas) o hackeos a la conexión de base de datos, `tenant_partition` utiliza características nativas de PostgreSQL para dividir tablas gigantes en tablas físicas más pequeñas por tenant (Cliente, ISP, Organización, etc.), manteniendo la experiencia de desarrollo de ActiveRecord estándar.

## 🚀 Características Principales

* **API Simple (Opt-in):** Usa `partition_table` en tus modelos para activar la magia.
* **Soporte Nativo CPK:** Compatible con **Composite Primary Keys** de Rails 7.1+.
* **Sin Magic Strings:** Usa métodos explícitos (`create_partition`, `drop_partition`).
* **Gestión de Datos Huérfanos:** Herramientas para mover datos de la tabla "Default" a su partición correcta automáticamente.
* **Safety Guards:** Protección contra borrados accidentales en Producción.
* **Tasks de Mantenimiento:** Rake tasks integradas para auditoría y limpieza.

---

## 📦 Instalación

Agrega esto a tu `Gemfile`:

```ruby
gem 'tenant_partition'
```

Y ejecuta:

```bash
bundle install
```

---

## ⚙️ Configuración Inicial

Crea un inicializador para definir tu clave de partición global (por ejemplo, `:isp_id`, `:account_id`, `:tenant_id`).

```ruby
# config/initializers/tenant_partition.rb

TenantPartition.configure do |config|
  # Esta es la columna que actuará como discriminador global
  config.partition_key = :isp_id
end
```

---

## 🏗 Estrategias de Uso

La gema utiliza un patrón "Opt-In". Incluir el módulo no altera tus modelos hasta que lo activas explícitamente. Puedes elegir la estrategia que mejor se adapte a tu proyecto:

### Opción A: Global (Recomendado)
Incluye el concern en `ApplicationRecord`. Esto **NO** particiona tus tablas, solo habilita la posibilidad de usar la macro `partition_table` en el futuro. Es ideal para mantener el código limpio.

```ruby
# app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Habilita la herramienta, pero permanece inactiva por defecto.
  include TenantPartition::Concerns::Partitioned
end
```

### Opción B: Local (A la carta)
Si prefieres no tocar `ApplicationRecord` o estás en un sistema legacy, puedes incluir el concern solo en los modelos específicos.

```ruby
# app/models/conversation.rb
class Conversation < ApplicationRecord
  include TenantPartition::Concerns::Partitioned
  partition_table # Activación inmediata
end
```

---

## 📖 Referencia de Macros y Métodos

Una vez que incluyes `TenantPartition::Concerns::Partitioned` en tu clase, obtienes acceso a las siguientes herramientas:

### 1. La Macro de Activación: `partition_table`

Es el interruptor de encendido. Debe llamarse al inicio de la definición del modelo.

```ruby
class Conversation < ApplicationRecord
  # Uso estándar (usa la key configurada globalmente, ej: :isp_id)
  partition_table

  # Uso personalizado (para modelos con keys únicas, ej: :year)
  # partition_table key: :year
end
```

**¿Qué hace esta macro internamente?**
1.  Configura la **Primary Key Compuesta** (`[:id, :partition_key]`).
2.  Registra el modelo en el sistema de mantenimiento de la gema.
3.  Inyecta los métodos de gestión de infraestructura (ver abajo).
4.  Agrega el scope `for_partition(value)`.

### 2. Métodos de Gestión de Infraestructura (Class Methods)

Estos métodos se inyectan en tu modelo **solo después** de llamar a `partition_table`. Úsalos para gestionar el ciclo de vida de las tablas físicas.

| Método | Descripción | Ejemplo |
| :--- | :--- | :--- |
| `create_partition(val)` | Crea la tabla física en Postgres (`CREATE TABLE ... PARTITION OF ...`). | `Conversation.create_partition(100)` |
| `drop_partition(val)` | Elimina la tabla física y sus datos (`DROP TABLE ...`). | `Conversation.drop_partition(100)` |
| `partition_table_exists?(val)` | Devuelve `true` si la tabla física existe en la BD. | `Conversation.partition_table_exists?(100)` |
| `partition_table_name(val)` | Devuelve el nombre real de la tabla hija. | `Conversation.partition_table_name(100)` <br> *=> "conversations_isp_100"* |

---

## 🛠 Guía de Implementación

### 1. Migración de Base de Datos

PostgreSQL necesita que la tabla padre se cree con la opción `PARTITION BY LIST`.

```ruby
class CreateConversations < ActiveRecord::Migration[7.1]
  def up
    # 1. Crear la tabla padre particionada (id: false es importante)
    create_table :conversations, id: false, options: "PARTITION BY LIST (isp_id)" do |t|
      t.bigserial :id, null: false
      t.integer :isp_id, null: false # Tu partition key

      t.string :subject
      t.timestamps
    end

    # 2. Definir la Primary Key Compuesta (Requerido por Postgres)
    execute "ALTER TABLE conversations ADD PRIMARY KEY (id, isp_id);"

    # 3. Crear tabla DEFAULT (Recomendado para evitar errores de inserción)
    execute "CREATE TABLE conversations_default PARTITION OF conversations DEFAULT;"
  end
# ...
```

### 2. Callbacks de Aprovisionamiento

Es común automatizar la creación de particiones cuando se crea un nuevo Tenant (ej. un nuevo ISP o Cliente).

```ruby
# app/models/isp.rb
class Isp < ApplicationRecord
  after_create :provision_infrastructure

  def provision_infrastructure
    # Método helper que crea las particiones en TODOS los modelos registrados
    TenantPartition.create!(self.id)
  end
end
```

---

## 🧹 Mantenimiento y Datos Huérfanos

Si insertas datos con un `isp_id` para el cual no has creado una partición (y tienes una tabla `DEFAULT`), los datos caerán ahí.

### Auditoría
Verifica si tienes datos en las tablas default:

```bash
bundle exec rake tenant_partition:audit
# [TenantPartition] [AUDIT] Iniciando auditoría...
# [TenantPartition] [ALERTA] Conversation: 450 registros huérfanos encontrados.
```

### Limpieza (Cleanup)
Crea las particiones faltantes y mueve los datos automáticamente:

```bash
bundle exec rake tenant_partition:cleanup
# [TenantPartition] [FIX] Conversation: Procesando 2 tenants con datos huérfanos.
# [TenantPartition] [MOVE] -> ID 101: 450 registros recuperados.
```

---

## 🛡️ Producción y Seguridad

La gema incluye un `SafetyGuard` que impide ejecutar comandos destructivos (`drop_partition`, `destroy!`) en entorno de producción a menos que se fuerce explícitamente.

Para ejecutar tareas destructivas en producción, debes setear la variable de entorno:

```bash
DISABLE_TENANT_PARTITION_GUARD=true bundle exec rake tenant_partition:destroy_tenant[123]
```

---

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
