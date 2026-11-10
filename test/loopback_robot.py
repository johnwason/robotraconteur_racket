"""Loopback robot driver for interop testing.

A minimal AbstractRobot driver (based on the ABB minimal example in
robotraconteur_abstract_robot_python) with no hardware: every joint position
command is fed straight back as the measured joint position on the next
timestep. The robot is always enabled and ready.

    python3 test/loopback_robot.py [port]

Serves com.robotraconteur.robotics.robot.Robot at
rr+tcp://localhost:<port>/?service=robot (default port 59926).
"""

import os
import sys
import threading
import time

import numpy as np
import RobotRaconteur as RR
import RobotRaconteurCompanion as RRC
from RobotRaconteurCompanion.Util.InfoFileLoader import InfoFileLoader
from RobotRaconteurCompanion.Util.AttributesUtil import AttributesUtil
from robotraconteur_abstract_robot import AbstractRobot

RRN = RR.RobotRaconteurNode.s


class LoopbackRobot(AbstractRobot):
    def __init__(self, robot_info):
        super().__init__(robot_info, 6)
        self._uses_homing = False
        self._has_position_command = True
        self._has_velocity_command = False
        self._update_period = 10e-3
        self._base_set_controller_state = True
        self._base_set_operational_mode = True
        self._loopback_pos = np.zeros((6,))
        self._loopback_lock = threading.Lock()

    def _run_timestep(self, now):
        with self._loopback_lock:
            pos = np.copy(self._loopback_pos)
        self._last_joint_state = now
        self._last_endpoint_state = now
        self._last_robot_state = now
        self._enabled = True
        self._ready = True
        self._joint_position = pos
        self._endpoint_pose = self._calc_endpoint_poses()
        super()._run_timestep(now)

    def _send_robot_command(self, now, joint_pos_cmd, joint_vel_cmd):
        if joint_pos_cmd is not None:
            with self._loopback_lock:
                self._loopback_pos = np.copy(joint_pos_cmd)

    def _send_disable(self, handler):
        raise RR.NotImplementedException("Unsupported function")

    def _send_enable(self, handler):
        raise RR.NotImplementedException("Unsupported function")

    def _send_reset_errors(self, handler):
        raise RR.NotImplementedException("Unsupported function")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 59926
    here = os.path.dirname(os.path.abspath(__file__))

    RRC.RegisterStdRobDefServiceTypes(RRN)
    with open(os.path.join(here, "abb_1200_5_90_robot_default_config.yml")) as f:
        robot_info_text = f.read()
    robot_info, _ = InfoFileLoader(RRN).LoadInfoFileFromString(
        robot_info_text, "com.robotraconteur.robotics.robot.RobotInfo", "device")
    attributes = AttributesUtil(RRN).GetDefaultServiceAttributesFromDeviceInfo(robot_info.device_info)

    robot = LoopbackRobot(robot_info)
    robot._start_robot()
    time.sleep(0.5)
    try:
        with RR.ServerNodeSetup("experimental.loopback_robot", port):
            ctx = RRN.RegisterService("robot", "com.robotraconteur.robotics.robot.Robot", robot)
            ctx.SetServiceAttributes(attributes)
            print("READY", flush=True)
            while True:
                time.sleep(1)
    finally:
        robot._close()


if __name__ == "__main__":
    main()
