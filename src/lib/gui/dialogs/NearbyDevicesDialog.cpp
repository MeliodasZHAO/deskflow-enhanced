// SPDX-FileCopyrightText: (C) 2026 Deskflow Developers
// SPDX-License-Identifier: GPL-2.0-only WITH LicenseRef-OpenSSL-Exception
#include "NearbyDevicesDialog.h"
#include "common/LabExecutionPolicy.h"
#include "gui/ExperienceStyle.h"
#include "gui/core/DeviceRecovery.h"
#include "gui/core/DiscoveryCatalog.h"
#include "gui/core/NearbyDiscovery.h"
#include "gui/core/RecoveryProbe.h"
#include <QComboBox>
#include <QDialogButtonBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QListWidget>
#include <QPushButton>
#include <QSignalBlocker>
#include <QTimer>
#include <QUuid>
#include <QVBoxLayout>
namespace deskflow::gui {
NearbyDevicesDialog::NearbyDevicesDialog(
    QWidget *parent, DiscoveryScopeSource source, IdentityBindings *bindings, const QString &expected,
    ScopedAddressResolver *resolver
)
    : QDialog(parent),
      m_discovery(new NearbyDiscovery(this)),
      m_devices(new QListWidget(this))
{
  if (bindings && bindings->devices().contains(IdentityBindings::normalizedFingerprint(expected)))
    m_recovery = new DeviceRecovery(*bindings, *m_discovery, this);
  if (deskflow::lab::kCandidateExecutionEnabled && !m_recovery && !resolver)
    resolver = createScopedAddressResolver(this, source, [this](const QString &host, int port) {
      return m_discovery->serviceNames(host, port);
    });
  deskflow::gui::applyExperienceStyle(this);
  setWindowTitle(tr("Nearby computers"));
  resize(620, 460);
  setMinimumWidth(540);
  auto *layout = new QVBoxLayout(this);
  layout->setContentsMargins(24, 24, 24, 20);
  layout->setSpacing(14);
  auto *title = new QLabel(tr("Nearby computers"), this);
  title->setObjectName("nearbyHeading");
  auto titleFont = title->font();
  titleFont.setPointSizeF(titleFont.pointSizeF() + 6);
  titleFont.setBold(true);
  title->setFont(titleFont);
  layout->addWidget(title);
  auto *help = new QLabel(
      tr("On the computer providing the keyboard and mouse, start sharing and enable discovery. Search for the "
         "temporary name shown on that computer."),
      this
  );
  if (m_recovery)
    help->setText(
        tr("Find the saved device on this network. Its address will change only after TLS verifies the same complete "
           "identity.")
    );
  help->setWordWrap(true);
  help->setTextFormat(Qt::PlainText);
  layout->addWidget(help);
  auto *network = new QComboBox(this);
  network->setObjectName("nearbyNetwork");
  network->setAccessibleName(tr("Local network for discovery"));
  auto *networkLabel = new QLabel(tr("Local network for discovery"), this);
  networkLabel->setObjectName("nearbyNetworkLabel");
  networkLabel->setBuddy(network);
  layout->addWidget(networkLabel);
  auto scopes = std::make_shared<QVector<DiscoveryScope>>();
  auto reload = [this, network, scopes, source] {
    m_discovery->stop();
    m_devices->clear();
    const QSignalBlocker blocker(network);
    *scopes = source();
    network->clear();
    network->addItem(tr("Choose a private Wi-Fi or Ethernet network"));
    for (const auto &scope : *scopes)
      network->addItem(tr("%1 · %2").arg(scope.name, scope.address.toString()));
    if (!m_recovery && scopes->size() == 1)
      network->setCurrentIndex(1);
  };
  reload();
  auto *networkRow = new QHBoxLayout;
  auto *reloadButton = new QPushButton(tr("Refresh networks"), this);
  reloadButton->setObjectName("refreshNetworks");
  networkRow->addWidget(network, 1);
  networkRow->addWidget(reloadButton);
  layout->addLayout(networkRow);
  m_devices->setObjectName("nearbyDevices");
  m_devices->setAccessibleName(tr("Discovered computers"));
  layout->addWidget(m_devices, 1);
  auto *empty = new QLabel(this);
  empty->setObjectName("nearbyEmpty");
  empty->setWordWrap(true);
  empty->setAlignment(Qt::AlignCenter);
  empty->setContentsMargins(24, 24, 24, 24);
  layout->addWidget(empty, 1);
  const auto updateEmpty = [this, empty] {
    const bool hasDevices = m_devices->count() > 0;
    m_devices->setVisible(hasDevices);
    empty->setVisible(!hasDevices);
  };
  connect(m_devices->model(), &QAbstractItemModel::rowsInserted, this, updateEmpty);
  connect(m_devices->model(), &QAbstractItemModel::rowsRemoved, this, updateEmpty);
  connect(m_devices->model(), &QAbstractItemModel::modelReset, this, updateEmpty);
  updateEmpty();
  auto *statusLabel = new QLabel(this);
  statusLabel->setObjectName("nearbyStatus");
  statusLabel->setTextFormat(Qt::PlainText);
  statusLabel->setWordWrap(true);
  layout->addWidget(statusLabel);
  auto *buttons = new QDialogButtonBox(QDialogButtonBox::Cancel, this);
  auto *select = buttons->addButton(tr("Connect"), QDialogButtonBox::AcceptRole);
  select->setEnabled(false);
  select->setObjectName("selectNearbyAddress");
  if (m_recovery)
    select->hide();
  auto *refresh = buttons->addButton(
      m_recovery ? tr("Search for 2 minutes") : tr("Search"), QDialogButtonBox::ActionRole
  );
  refresh->setObjectName("refreshNearby");
  layout->addWidget(buttons);
  if (!m_recovery) {
    auto *manual = buttons->addButton(tr("Enter address…"), QDialogButtonBox::ActionRole);
    manual->setObjectName("nearbyManualEntry");
    connect(manual, &QPushButton::clicked, this, [this] {
      reject();
      Q_EMIT manualEntryRequested();
    });
  }
  if (m_recovery) {
    auto *credentials = buttons->addButton(tr("Choose test credentials…"), QDialogButtonBox::ActionRole);
    credentials->setObjectName("chooseProbeCredentials");
    credentials->setEnabled(deskflow::lab::kProbeNetworkExecutionEnabled);
    credentials->setToolTip(tr(
        "Only explicitly prepared isolated test credentials are accepted. Production identity files are never imported."
    ));
    connect(credentials, &QPushButton::clicked, this, &NearbyDevicesDialog::preparedSessionRequested);
#if defined(DESKFLOW_CANDIDATE_BUILD) || !defined(DESKFLOW_LAB_BUILD)
    credentials->hide();
#endif
  }
  const auto updateNetwork = [this, network, scopes, refresh, empty, statusLabel] {
    refresh->setEnabled(network->currentIndex() > 0);
    empty->setText(
        m_recovery ? tr("Choose a network and search for the saved computer.")
        : scopes->isEmpty() ? tr("No eligible local network was found. Enter the other computer’s address.")
        : network->currentIndex() == 0 ? tr("Choose a network before searching, or enter the address directly.")
                                       : tr("No computers found yet. Search or enter the address directly.")
    );
    statusLabel->clear();
  };
  updateNetwork();
  connect(network, &QComboBox::currentIndexChanged, this, [this, updateNetwork] {
    if (m_recovery)
      m_recovery->cancel();
    m_discovery->stop();
    m_devices->clear();
    updateNetwork();
  });
  connect(refresh, &QPushButton::clicked, this, [this, network, scopes, expected] {
    const auto index = network->currentIndex() - 1;
    if (index >= 0 && index < scopes->size()) {
      if (m_recovery && !m_recovery->begin(expected, (*scopes)[index]))
        return;
      m_discovery->start((*scopes)[index]);
    }
  });
  connect(reloadButton, &QPushButton::clicked, this, [reload, updateNetwork] {
    reload();
    updateNetwork();
  });
  connect(this, &QDialog::finished, m_discovery, &NearbyDiscovery::stop);
  if (m_recovery) {
    connect(this, &QDialog::finished, m_recovery, &DeviceRecovery::cancel);
    connect(m_recovery, &DeviceRecovery::recovered, this, [this](const QString &fp, const QString &host, int port) {
      accept();
      Q_EMIT verifiedEndpoint(fp, host, port);
    });
    connect(m_recovery, &DeviceRecovery::stateChanged, this, [this, statusLabel](DeviceRecovery::State state) {
      using S = DeviceRecovery::State;
      if (state == S::Verifying)
        statusLabel->setText(tr("Checking the saved identity. The address has not been saved."));
      else if (state == S::Backoff)
        statusLabel->setText(tr("Candidate rejected. Waiting before checking another address."));
      else if (state == S::NeedsAction) {
        m_discovery->stop();
        statusLabel->setText(tr("Verification needs attention. The saved address and trust are unchanged."));
      }
    });
  }
  connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);
  const auto confirmEndpoint = [this](const QString &host, int port) {
    // Finishing the dialog stops discovery and clears the selected item.
    m_connectionHost = host;
    m_connectionPort = port;
    accept();
  };
  auto attempt = std::make_shared<deskflow::auth::Context>();
  connect(buttons, &QDialogButtonBox::accepted, this, [=, this] {
    const auto host = selectedHost();
    const auto port = selectedPort();
    if (m_recovery || !NearbyDiscovery::validEndpoint(host, port))
      return;
    if (!resolver) {
      confirmEndpoint(host, port);
      return;
    }
    if (attempt->valid())
      return;
    const auto index = network->currentIndex() - 1;
    if (index < 0 || index >= scopes->size())
      return;
    *attempt = {QUuid::createUuid().toString(QUuid::Id128), {}, 1};
    select->setEnabled(false);
    statusLabel->setText(tr("Looking up the local address…"));
    resolver->start(*attempt, (*scopes)[index], host, port);
  });
  const auto updateSelection = [this, select, resolver, attempt] {
    if (attempt->valid()) {
      *attempt = {};
      resolver->cancel();
    }
    select->setEnabled(NearbyDiscovery::validEndpoint(selectedHost(), selectedPort()));
  };
  connect(m_devices, &QListWidget::currentRowChanged, this, updateSelection);
  if (resolver) {
    connect(this, &QDialog::finished, resolver, &ScopedAddressResolver::cancel);
    const auto addressUnavailable = [statusLabel, updateSelection] {
      updateSelection();
      statusLabel->setText(tr("Could not find a single local address. Search again or enter the address directly."));
    };
    connect(resolver, &ScopedAddressResolver::failed, this, [attempt, addressUnavailable](const auto &context) {
      if (context == *attempt)
        addressUnavailable();
    });
    connect(
        resolver, &ScopedAddressResolver::addresses, this,
        [this, attempt, confirmEndpoint, addressUnavailable](
            const auto &context, const DiscoveryScope &scope, const QString &host, const QStringList &addresses
        ) {
          if (context != *attempt)
            return;
          if (host != selectedHost() || addresses.size() != 1 || !validProbeAddress(scope, QHostAddress(addresses[0]))) {
            addressUnavailable();
            return;
          }
          *attempt = {};
          confirmEndpoint(addresses[0], selectedPort());
        }
    );
  }
  connect(m_discovery, &NearbyDiscovery::status, statusLabel, &QLabel::setText);
  connect(m_discovery, &NearbyDiscovery::searchingChanged, this, &NearbyDevicesDialog::searchingChanged);
  connect(m_discovery, &NearbyDiscovery::removed, this, [this](const QString &key) {
    const bool lostSelection =
        m_devices->currentItem() && m_devices->currentItem()->data(Qt::UserRole).toString() == key;
    for (int i = m_devices->count() - 1; i >= 0; --i)
      if (m_devices->item(i)->data(Qt::UserRole).toString() == key)
        delete m_devices->takeItem(i);
    if (lostSelection)
      m_devices->setCurrentRow(-1);
  });
  connect(
      m_discovery, &NearbyDiscovery::found, this,
      [this](const QString &key, const QString &name, const QString &host, int port) {
        if (!NearbyDiscovery::validEndpoint(host, port) || !DiscoveryCatalog::validName(name))
          return;
        QListWidgetItem *item = nullptr;
        for (int i = 0; i < m_devices->count(); ++i)
          if (m_devices->item(i)->data(Qt::UserRole).toString() == key)
            item = m_devices->item(i);
        if (!item) {
          if (m_devices->count() >= 64)
            return;
          item = new QListWidgetItem(m_devices);
        }
        if (item == m_devices->currentItem() &&
            (item->data(Qt::UserRole + 1).toString() != host || item->data(Qt::UserRole + 2).toInt() != port))
          m_devices->setCurrentRow(-1); // Address replacement needs a fresh explicit selection.
        item->setText(tr("%1\n%2 · port %3 · identity unverified").arg(name.left(128), host).arg(port));
        item->setData(Qt::UserRole, key);
        item->setData(Qt::UserRole + 1, host);
        item->setData(Qt::UserRole + 2, port);
      }
  );
}
QString NearbyDevicesDialog::selectedHost() const
{
  auto *item = m_devices->currentItem();
  return item ? item->data(Qt::UserRole + 1).toString() : QString();
}
int NearbyDevicesDialog::selectedPort() const
{
  auto *item = m_devices->currentItem();
  return item ? item->data(Qt::UserRole + 2).toInt() : 0;
}
} // namespace deskflow::gui
