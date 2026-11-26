// SPDX-FileCopyrightText: (C) 2026 Deskflow Developers
// SPDX-License-Identifier: GPL-2.0-only WITH LicenseRef-OpenSSL-Exception
#pragma once
#include "gui/core/DiscoveryScope.h"
#include <QDialog>
class QListWidget;
namespace deskflow::gui {
class NearbyDiscovery;
class IdentityBindings;
class DeviceRecovery;
class ScopedAddressResolver;
class NearbyDevicesDialog : public QDialog
{
  Q_OBJECT
public:
  explicit NearbyDevicesDialog(
      QWidget *parent = nullptr, DiscoveryScopeSource source = DiscoveryScope::current,
      IdentityBindings *bindings = nullptr, const QString &expected = {}, ScopedAddressResolver *resolver = nullptr
  );
  DeviceRecovery *recovery() const
  {
    return m_recovery;
  }
  QString selectedHost() const;
  int selectedPort() const;
  QString connectionHost() const
  {
    return m_connectionHost;
  }
  int connectionPort() const
  {
    return m_connectionPort;
  }
Q_SIGNALS:
  void searchingChanged(bool active);
  void manualEntryRequested();
  void preparedSessionRequested();
  void verifiedEndpoint(const QString &fingerprint, const QString &host, int port);

private:
  NearbyDiscovery *m_discovery;
  QListWidget *m_devices;
  DeviceRecovery *m_recovery = nullptr;
  QString m_connectionHost;
  int m_connectionPort = 0;
};
} // namespace deskflow::gui
