import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'app/MultiSessionAIManager/Resources/msam-metrics.py'
spec = importlib.util.spec_from_file_location('mac_activity_metrics', SOURCE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class MacActivityTests(unittest.TestCase):
    def test_mac_core_map_uses_interval_ticks_and_handles_reset(self):
        m._mac_cpu_previous = None
        with patch.object(m, 'mac_cpu_ticks', side_effect=[
                [(10, 5, 80, 5), (20, 5, 70, 5)],
                [(20, 10, 160, 10), (70, 15, 100, 15)],
                [(1, 1, 1, 1), (1, 1, 1, 1)]]):
            self.assertEqual(m.mac_core_usage(), [])
            self.assertEqual(m.mac_core_usage(), [20, 70])
            self.assertEqual(m.mac_core_usage(), [])

    def test_mac_network_counts_link_rows_once_using_named_byte_columns(self):
        output = '''Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
en0 1500 <Link#4> aa:bb 100 0 10000 200 0 20000 0
en0 1500 192.168.1 192.168.1.2 100 0 10000 200 0 20000 0
en1 1500 <Link#5> aa:cc 50 0 5000 100 0 6000 0
lo0 16384 <Link#1> 00:00 999 0 999999 999 0 999999 0
awdl0 1500 <Link#6> aa:dd 100 0 10000 200 0 20000 0
'''
        self.assertEqual(m.mac_network_counters(output), {'en0': (10000, 20000), 'en1': (5000, 6000)})

    def test_mac_identity_without_utilization_does_not_claim_idle_gpu(self):
        m._mac_gpu_identity = ('Intel GPU', 0)
        with patch.object(m.subprocess, 'check_output', side_effect=OSError):
            gpu = m.get_mac_gpu()
        self.assertEqual(gpu['modelName'], 'Intel GPU')
        self.assertIs(gpu.get('utilizationAvailable'), False)


if __name__ == '__main__':
    unittest.main()
