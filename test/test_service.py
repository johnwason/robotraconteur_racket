"""Reference Robot Raconteur service (Python) used to test the Racket client."""

import os
import sys
import threading
import time

import numpy as np
import RobotRaconteur as RR

RRN = RR.RobotRaconteurNode.s

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 22222


class SubObj:
    def __init__(self, name):
        self.name = name

    def add(self, a, b):
        return a + b


class TestObject:
    def __init__(self):
        self.d1 = 1.5
        self.i1 = -42
        self.u8arr = np.array([1, 2, 3], dtype=np.uint8)
        self.darr = np.array([1.0, 2.0, 3.5])
        self.dfix = np.array([7.0, 8.0, 9.0])
        self.s1 = "hello from python"
        self.b1 = True
        self.c1 = complex(1.0, -2.0)
        self.md = np.arange(6, dtype=np.float64).reshape((2, 3), order="F")
        st = RRN.NewStructure("experimental.racket_test.TestStruct")
        st.d = 3.25
        st.darr = np.array([4.0, 5.0])
        st.s = "struct string"
        st.imap = {"one": 1, "two": 2}
        st.v = RR.VarValue("var in struct", "string")
        self.st = st
        self.dmap = {"a": 1.0, "b": 2.0}
        self.smap = {1: "x", 5: "y"}
        self.slist = ["p", "q", "r"]
        self.var1 = RR.VarValue(np.array([1, 2, 3], dtype=np.int32), "int32[]")
        self.color = 0x10
        pod_dt = RRN.GetPodDType("experimental.racket_test.TestPod")
        p = np.zeros((1,), dtype=pod_dt)
        p[0]["a"] = 1.25
        p[0]["b"] = [1, 2, 3]
        self.pod1 = p
        pa = np.zeros((2,), dtype=pod_dt)
        pa[0]["a"] = 10.0
        pa[1]["a"] = 20.0
        pa[1]["b"] = [4, 5, 6]
        self.podarr = pa
        vec_dt = RRN.GetNamedArrayDType("experimental.racket_test.Vec3")
        v = np.zeros((1,), dtype=vec_dt)
        v[0]["x"] = 1.0
        v[0]["y"] = 2.0
        v[0]["z"] = 3.0
        self.vec = v
        pose_dt = RRN.GetNamedArrayDType("experimental.racket_test.Pose")
        pose = np.zeros((1,), dtype=pose_dt)
        pose[0]["position"]["x"] = 0.5
        pose[0]["orientation"] = [1.0, 0.0, 0.0, 0.0]
        self.pose = pose
        self.poses = np.zeros((3,), dtype=pose_dt)
        self.readonly_prop = 99.0

        self.ev1 = RR.EventHook()
        self.sub = SubObj("sub")
        self._subs = {1: SubObj("one"), 2: SubObj("two")}
        self._named = {"a b": SubObj("named a b")}
        self.last_w_out = None

    # Wire and pipe server objects are assigned by the RR library after
    # registration; set up broadcasters/receivers in the property setters.
    @property
    def w_in(self):
        return self._w_in

    @w_in.setter
    def w_in(self, value):
        self._w_in = value
        self._w_in_b = RR.WireBroadcaster(value)
        self._w_in_b.OutValue = np.array([0.0])
        self._running = True
        threading.Thread(target=self._wire_loop, daemon=True).start()

    @property
    def w_out(self):
        return self._w_out

    @w_out.setter
    def w_out(self, value):
        self._w_out = value
        self._w_out_r = RR.WireUnicastReceiver(value)
        self._w_out_r.InValueChanged += self._w_out_changed

    @property
    def p1(self):
        return self._p1

    @p1.setter
    def p1(self, value):
        self._p1 = value
        value.PipeConnectCallback = self._p1_connected

    def _w_out_changed(self, value, ts, ep):
        self.last_w_out = value
        print("w_out received", value, flush=True)

    def _p1_connected(self, ep):
        # echo every packet back on the same endpoint, doubled
        def recv(ep2):
            while ep2.Available > 0:
                v = ep2.ReceivePacket()
                ep2.SendPacket(np.asarray(v) * 2)

        ep.PacketReceivedEvent += recv

    def _wire_loop(self):
        i = 0
        while self._running:
            i += 1
            self._w_in_b.OutValue = np.array([float(i), float(i) * 2])
            time.sleep(0.05)

    def add(self, a, b):
        return a + b

    def fire_event(self, msg):
        self.s1 = msg
        self.ev1.fire(msg, 12.5)

    def concat(self, parts):
        return "-".join(parts)

    def make_struct(self, d, s):
        st = RRN.NewStructure("experimental.racket_test.TestStruct")
        st.d = d
        st.darr = np.array([d, d * 2])
        st.s = s
        st.imap = {"len": len(s)}
        st.v = None
        return st

    def raise_error(self):
        raise RR.InvalidOperationException("this is an expected test error")

    def count_to(self, n):
        return CountGen(n)

    def accumulate(self):
        return AccumGen()

    def call_my_callback(self, a):
        ep = RR.ServerEndpoint.GetCurrentEndpoint()
        f = self.cb1.GetClientFunction(ep)
        return f(a) + 1000.0

    def get_subs(self, ind):
        return self._subs[int(ind)], "experimental.racket_test.SubObj"

    def get_named_subs(self, ind):
        return self._named[ind], "experimental.racket_test.SubObj"

    def get_sub(self):
        return self.sub, "experimental.racket_test.SubObj"


class CountGen:
    def __init__(self, n):
        self.i = 0
        self.n = n

    def Next(self):
        if self.i >= self.n:
            raise RR.StopIterationException("done")
        self.i += 1
        return float(self.i)

    def Abort(self):
        pass

    def Close(self):
        pass


class AccumGen:
    def __init__(self):
        self.total = 0.0

    def Next(self, x):
        self.total += x
        return self.total

    def Abort(self):
        pass

    def Close(self):
        pass


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "experimental.racket_test.robdef")) as f:
        robdef = f.read()

    # Tests run in a container with --network none, so discovery traffic
    # never leaves the container.
    # RR_TEST_TLS_NODEID: run as a secure server (TLS required) with this
    # NodeID; the node certificate is read from
    # <config dir>/certificates/<nodeid>.p12 (ROBOTRACONTEUR_USER_CONFIG_DIR, or
    # ROBOTRACONTEUR_SYSTEM_CONFIG_DIR when running as root, e.g. in the container)
    tls_nodeid = os.environ.get("RR_TEST_TLS_NODEID")
    if tls_nodeid:
        # (no node name: a name would assign its own stored NodeID first)
        setup = RR.SecureServerNodeSetup("", PORT,
                                         argv=["--robotraconteur-nodeid=" + tls_nodeid,
                                               "--robotraconteur-local-enable=false"])
    else:
        # RR_TEST_NODENAME: node name, so several services can run as separate
        # nodes in one namespace (discovery tests)
        setup = RR.ServerNodeSetup(os.environ.get("RR_TEST_NODENAME", "experimental.racket_test"), PORT)
    with setup:
        RRN.RegisterServiceType(robdef)
        obj = TestObject()
        ctx = RRN.RegisterService("test", "experimental.racket_test.TestObject", obj)
        ctx.SetServiceAttributes({"description": RR.VarValue("racket test service", "string")})
        print("READY", flush=True)
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
