.. _yearn-v3-periphery:

Периферийные модули (Periphery)
================================

Архитектура Yearn V3 построена с расчётом на модульность и гибкость — любой пользователь может развернуть и адаптировать собственное хранилище (Vault). Базовый код намеренно оставлен минималистичным и «непредвзятым», а дополнительный функционал добавляется через опциональные контракты — **Periphery-модули**.

Ниже приведён неполный список существующих периферийных контрактов, разработанных и развёрнутых для помощи тем, кто желает создать и управлять своими V3-хранилищами.

**Репозитории:**

- Vault Periphery: https://github.com/yearn/vault-periphery
- TokenizedStrategy Periphery: https://github.com/yearn/tokenized-strategy-periphery

**Адрес провайдера адресов протокола:**
``0x775F09d6f3c8D2182DFA8bce8628acf51105653c`` — содержит адреса большинства развернутых контрактов Periphery и их фабрик.

Vault Periphery
----------------

Контракты в этом разделе предназначены для использования с мультистратегийными хранилищами V3.

Release Registry
~~~~~~~~~~~~~~~~

Контракт: `ReleaseRegistry.sol <https://github.com/yearn/vault-periphery/blob/master/contracts/registry/ReleaseRegistry.sol>`_

Реестр, отслеживающий версии Vault Factory, развернутые на конкретной цепочке. Каждый раз при выпуске новой версии она добавляется в реестр.

Registry
~~~~~~~~

Контракт: `Registry.sol <https://github.com/yearn/vault-periphery/blob/master/contracts/registry/Registry.sol>`_

Хранит одобренные (endorsed) мульти- и одностратегийные хранилища. Может использоваться для деплоя новых хранилищ на основе последней версии Vault Factory.

Метод ``newEndorsedVault(...)`` позволяет развернуть и сразу одобрить новое хранилище.

Можно развернуть кастомный реестр через ``RegistryFactory``.

Accountant
~~~~~~~~~~

Контракты: `accountants <https://github.com/yearn/vault-periphery/tree/master/contracts/accountants>`_

По умолчанию хранилища V3 имеют нулевые комиссии. Чтобы включить комиссии, необходимо установить ``accountant``.

``Accountant`` вызывается во время ``process_report``, получая данные об отчёте стратегии. Он может реализовывать:

- начисление комиссий (performance, management)
- возврат части дохода
- проверки устойчивости (healthchecks)
- авто-реинвестирование наград
- создание tranches
- разные уровни комиссий в зависимости от дохода/TVL

Деплой осуществляется через ``Accountant Factory``, затем вызывается ``set_accountant()`` на хранилище.

Debt Allocator
~~~~~~~~~~~~~~

Контракты: `debtAllocators <https://github.com/yearn/vault-periphery/tree/master/contracts/debtAllocators>`_

Контракты для управления распределением долга между стратегиями. Получают роли ``DEBT_MANAGER`` и ``REPORTING_MANAGER``.

Основные параметры:

- ``targetDebtRatio`` — целевой процент долга для стратегии (в базисных пунктах)
- ``maxDebtRatio`` — максимальное значение долга
- ``minimumChange`` — минимальная сумма перемещения для обновления долга
- ``maxAcceptableBaseFee`` — лимит ``block.basefee`` для экономии газа
- ``maxDebtUpdateLoss`` — максимально допустимый убыток при обновлении (по умолчанию: 1 = 0.01%)
- ``keeper`` — адрес, имеющий право вызывать ``update_debt``
- ``manager`` — может обновлять параметры целевого и макс. долга

Для деплоя можно использовать ``Debt Allocator Factory``.

Role Manager
~~~~~~~~~~~~

Контракт: `RoleManager.sol <https://github.com/yearn/vault-periphery/blob/master/contracts/Managers/RoleManager.sol>`_

Упрощает развертывание и настройку ролей для мультистратегийных хранилищ. Все права и периферийные модули можно назначить при инициализации хранилища.

Также из ``Role Manager`` можно получить все адреса периферийных контрактов Yearn на конкретной цепи.

