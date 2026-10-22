"""Physical inventory must not turn logical pools into pretend hardware."""
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'app/MultiSessionAIManager/Resources/msam-metrics.py'
spec = importlib.util.spec_from_file_location('inventory_metrics', SOURCE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class StorageInventoryTests(unittest.TestCase):
    def test_linux_lists_unmounted_drives_and_never_assigns_lvm_free_to_each_disk(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, model in [('sda', 'System SSD'), ('sdb', 'Pool SSD'), ('sdc', 'Spare SSD')]:
                block = root / 'class/block' / name
                (block / 'device').mkdir(parents=True)
                (block / 'device/model').write_text(model)
                (block / 'size').write_text('209715200')  # 100 GiB, 512-byte sectors
            partition = root / 'class/block/sda1'
            partition.mkdir()
            (partition / 'partition').write_text('1')
            (partition / 'size').write_text('209715200')
            volumes = [
                {'id': 'sda', 'volumes': [{'id': '/dev/sda1', 'availableGB': 20}]},
                {'id': 'mapper/pool', 'volumes': [{'id': '/dev/mapper/pool', 'availableGB': 80}]},
            ]
            disks = m.linux_physical_disks(volumes, {'sda': 39}, str(root))
            self.assertEqual([d['id'] for d in disks], ['sda', 'sdb', 'sdc'])
            self.assertEqual(disks[0]['totalGB'], 100)
            self.assertEqual(disks[0]['availableGB'], 20)
            self.assertEqual(disks[0]['temperature'], 39)
            self.assertIsNone(disks[1]['availableGB'])
            self.assertIsNone(disks[2]['availableGB'])

            # A Btrfs mount names one member, but its free space belongs to
            # the whole pool and can exceed that member's physical capacity.
            volumes.append({'id': 'sdc', 'volumes': [
                {'id': '/dev/sdc1', 'fileSystem': 'btrfs', 'availableGB': 150}]})
            disks = m.linux_physical_disks(volumes, {}, str(root))
            self.assertIsNone(disks[2]['availableGB'])

    def test_nvme_namespaces_keep_separate_sizes_and_share_controller_temperature(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ['nvme0n1', 'nvme0n2']:
                block = root / 'class/block' / name
                block.mkdir(parents=True)
                (block / 'size').write_text('209715200')
            model = root / 'class/nvme/nvme0/model'
            model.parent.mkdir(parents=True)
            model.write_text('NVMe SSD')
            groups = [{'id': 'nvme0', 'volumes': [
                {'id': '/dev/nvme0n1p1', 'availableGB': 10},
                {'id': '/dev/nvme0n2p1', 'availableGB': 30}]}]
            disks = m.linux_physical_disks(groups, {'nvme0': 42}, str(root))
            self.assertEqual([d['availableGB'] for d in disks], [10, 30])
            self.assertEqual([d['temperature'] for d in disks], [42, 42])

    def test_mac_apfs_free_counted_once_and_hardware_model_comes_from_diskutil(self):
        fixtures = {
            ('diskutil', 'list', '-plist', 'physical'): {'AllDisksAndPartitions': [
                {'DeviceIdentifier': 'disk0', 'Size': 200 * 1024**3,
                 'Partitions': [{'DeviceIdentifier': 'disk0s2'}]}]},
            ('diskutil', 'info', '-plist', 'disk0'): {'MediaName': 'APPLE SSD'},
            ('diskutil', 'apfs', 'list', '-plist'): {'Containers': [
                {'ContainerReference': 'disk3', 'CapacityCeiling': 190 * 1024**3,
                 'CapacityFree': 50 * 1024**3,
                 'PhysicalStores': [{'DeviceIdentifier': 'disk0s2'}]}]},
        }
        def output(command, **kwargs):
            return plistlib.dumps(fixtures[tuple(command)])
        with patch.object(m.subprocess, 'check_output', side_effect=output):
            disks = m.mac_physical_disks([])
        self.assertEqual(len(disks), 1)
        self.assertEqual(disks[0]['id'], 'disk0')
        self.assertEqual(disks[0]['model'], 'APPLE SSD')
        self.assertEqual(disks[0]['totalGB'], 200)
        self.assertEqual(disks[0]['availableGB'], 50)
        self.assertIsNone(disks[0]['temperature'])

    def test_mac_fusion_pool_free_is_not_duplicated_on_physical_members(self):
        fixtures = {
            ('diskutil', 'list', '-plist', 'physical'): {'AllDisksAndPartitions': [
                {'DeviceIdentifier': 'disk0', 'Size': 100 * 1024**3},
                {'DeviceIdentifier': 'disk1', 'Size': 100 * 1024**3}]},
            ('diskutil', 'apfs', 'list', '-plist'): {'Containers': [
                {'CapacityFree': 80 * 1024**3, 'PhysicalStores': [
                    {'DeviceIdentifier': 'disk0s2'}, {'DeviceIdentifier': 'disk1s2'}]}]},
        }
        def output(command, **kwargs):
            return plistlib.dumps(fixtures.get(tuple(command), {}))
        with patch.object(m.subprocess, 'check_output', side_effect=output):
            disks = m.mac_physical_disks([])
        self.assertEqual([d['availableGB'] for d in disks], [None, None])

    def test_mac_inventory_unavailable_does_not_invent_hardware(self):
        with patch.object(m.subprocess, 'check_output', side_effect=OSError):
            self.assertEqual(m.mac_physical_disks([]), [])


if __name__ == '__main__':
    unittest.main()
