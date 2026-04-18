```mermaid
flowchart LR
    subgraph vendors["Вендоры"]
        direction BT
        Вендор1 --> Вендор2
    end
    subgraph dev["Разработка"]
        direction BT
        Разработка --> РазработкаОбновленная
    end
    Вендор1 --> Разработка
    Вендор2 --> РазработкаОбновленная
```
