"""
Test for parallel MODFLOW running on two cpus.
Each case contains two coupled DISU models which are
generated from their DIS counterparts:

1d:  (nlay,nrow,ncol) = (1,1,5),
2d:  (nlay,nrow,ncol) = (1,5,5),
3d:  (nlay,nrow,ncol) = (5,5,5),

constant head boundaries left=1.0, right=10.0.
The result should be a uniform flow field.
"""

import os

import flopy
import numpy as np
import pytest
from flopy.utils.gridutil import get_disu_kwargs

from conftest import project_root_path
from framework import TestFramework

data_path = project_root_path / "autotest" / "data" / "par_gwf_disu_exg"
cases = [
    "par_gwf_disu1d",
    "par_gwf_disu2d",
    "par_gwf_disu3d",
    "par_gwf_disu1d_binary",
    "par_gwf_disu2d_binary",
    "par_gwf_disu3d_binary",
]
dis_shape = [(1, 1, 5), (1, 5, 5), (5, 5, 5), (1, 1, 5), (1, 5, 5), (5, 5, 5)]

# global convenience...
name_left = "leftmodel"
name_right = "rightmodel"

# solver data
nouter, ninner = 100, 300
hclose, rclose, relax = 10e-9, 1e-3, 0.97


def get_model(idx, dir):
    name = cases[idx]

    # parameters and spd
    # tdis
    nper = 1
    tdis_rc = []
    for i in range(nper):
        tdis_rc.append((1.0, 1, 1))

    # model spatial discretization
    nlay = dis_shape[idx][0]
    nrow = dis_shape[idx][1]
    ncol = dis_shape[idx][2]

    # cell spacing
    delr = 100.0
    delr_arr = delr * np.ones(ncol)
    delc = 100.0
    delc_arr = delc * np.ones(nrow)

    # shift
    shift_x = 5 * delr
    shift_y = 0.0

    # top/bot of the aquifer
    tops = [0.0, -100.0, -200.0, -300.0, -400.0, -500.0]

    # conversion to DISU
    disukwargs = get_disu_kwargs(
        nlay,
        nrow,
        ncol,
        delr_arr,
        delc_arr,
        tops[0],
        tops[1 : nlay + 1],
        return_vertices=True,
    )

    # hydraulic conductivity
    k11 = 1.0

    # boundary stress period data
    h_left = 1.0
    h_right = 10.0

    # initial head
    h_start = 0.0

    sim = flopy.mf6.MFSimulation(
        sim_name=name,
        version="mf6",
        exe_name="mf6",
        sim_ws=dir,
    )

    tdis = flopy.mf6.ModflowTdis(
        sim, time_units="DAYS", nper=nper, perioddata=tdis_rc
    )

    ims = flopy.mf6.ModflowIms(
        sim,
        print_option="ALL",
        outer_dvclose=hclose,
        outer_maximum=nouter,
        inner_maximum=ninner,
        inner_dvclose=hclose,
        rcloserecord=rclose,
        linear_acceleration="BICGSTAB",
        relaxation_factor=relax,
        pname="ims",
    )

    # submodel on the left:
    left_chd = [
        [(ilay * ncol * nrow + irow * ncol), h_left]
        for irow in range(nrow)
        for ilay in range(nlay)
    ]
    chd_spd_left = {0: left_chd}

    gwf = flopy.mf6.ModflowGwf(sim, modelname=name_left, save_flows=True)
    disu = flopy.mf6.ModflowGwfdisu(gwf, **disukwargs)
    ic = flopy.mf6.ModflowGwfic(gwf, strt=h_start)
    npf = flopy.mf6.ModflowGwfnpf(
        gwf,
        save_specific_discharge=False,  # let's skip angledegx
        save_flows=True,
        icelltype=0,
        k=k11,
    )
    chd = flopy.mf6.ModflowGwfchd(gwf, stress_period_data=chd_spd_left)
    oc = flopy.mf6.ModflowGwfoc(
        gwf,
        head_filerecord=f"{name_left}.hds",
        budget_filerecord=f"{name_left}.cbc",
        headprintrecord=[("COLUMNS", 10, "WIDTH", 15, "DIGITS", 6, "GENERAL")],
        saverecord=[("HEAD", "LAST"), ("BUDGET", "LAST")],
    )

    # submodel on the right:
    right_chd = [
        [(ilay * ncol * nrow + irow * ncol + ncol - 1), h_right]
        for irow in range(nrow)
        for ilay in range(nlay)
    ]
    chd_spd_right = {0: right_chd}

    gwf = flopy.mf6.ModflowGwf(sim, modelname=name_right, save_flows=True)
    disukwargs["xorigin"] = shift_x
    disukwargs["yorigin"] = shift_y
    disu = flopy.mf6.ModflowGwfdisu(gwf, **disukwargs)
    ic = flopy.mf6.ModflowGwfic(gwf, strt=h_start)
    npf = flopy.mf6.ModflowGwfnpf(
        gwf,
        save_specific_discharge=False,  # let's skip angledegx
        save_flows=True,
        icelltype=0,
        k=k11,
    )
    chd = flopy.mf6.ModflowGwfchd(gwf, stress_period_data=chd_spd_right)
    oc = flopy.mf6.ModflowGwfoc(
        gwf,
        head_filerecord=f"{name_right}.hds",
        budget_filerecord=f"{name_right}.cbc",
        headprintrecord=[("COLUMNS", 10, "WIDTH", 15, "DIGITS", 6, "GENERAL")],
        saverecord=[("HEAD", "LAST"), ("BUDGET", "LAST")],
    )

    # exchangedata
    angldegx = 0.0
    cdist = delr
    gwfgwf_data = [
        [
            (ilay * ncol * nrow + irow * ncol + ncol - 1),
            (ilay * ncol * nrow + irow * ncol),
            1,
            delr / 2.0,
            delr / 2.0,
            delc,
            angldegx,
            cdist,
        ]
        for irow in range(nrow)
        for ilay in range(nlay)
    ]

    if name.endswith("_binary"):
        exchangedata = {
            "factor": 1.0,
            "filename": "exg.bin",
            "data": None,
            "binary": True,
        }
        exg_fpath = data_path / f"par_gwf_disu{idx}_exg.txt"
        exg_fdata = np.loadtxt(
            exg_fpath,
            dtype={
                "names": (
                    "c11",
                    "c21",
                    "ihc",
                    "cl1",
                    "cl2",
                    "hwva",
                    "aux1",
                    "aux2",
                ),
                "formats": (
                    "i4",
                    "i4",
                    "i4",
                    "f8",
                    "f8",
                    "f8",
                    "f8",
                    "f8",
                ),
            },
        )
        exg_fdata.tofile(dir / "exg.bin")
    else:
        exchangedata = gwfgwf_data

    gwfgwf = flopy.mf6.ModflowGwfgwf(
        sim,
        exgtype="GWF6-GWF6",
        nexg=len(gwfgwf_data),
        exgmnamea=name_left,
        exgmnameb=name_right,
        exchangedata=exchangedata,
        auxiliary=["ANGLDEGX", "CDIST"],
        print_input=True,
    )

    return sim


def build_models(idx, test):
    sim = get_model(idx, test.workspace)
    return sim, None


def check_output(idx, test):
    pass
    # two coupled models with a uniform flow field,
    # here we assert the known head values at the
    # cell centers
    fpth = os.path.join(test.workspace, f"{name_left}.hds")
    hds = flopy.utils.HeadFile(fpth)
    heads_left = hds.get_data().flatten()
    fpth = os.path.join(test.workspace, f"{name_right}.hds")
    hds = flopy.utils.HeadFile(fpth)
    heads_right = hds.get_data().flatten()
    np.testing.assert_array_almost_equal(
        heads_left[0:5], [1.0, 2.0, 3.0, 4.0, 5.0]
    )
    np.testing.assert_array_almost_equal(
        heads_right[0:5], [6.0, 7.0, 8.0, 9.0, 10.0]
    )


@pytest.mark.parallel
@pytest.mark.parametrize("idx, name", enumerate(cases))
def test_mf6model(idx, name, function_tmpdir, targets):
    test = TestFramework(
        name=name,
        workspace=function_tmpdir,
        targets=targets,
        build=lambda t: build_models(idx, t),
        check=lambda t: check_output(idx, t),
        compare=None,
        parallel=True,
        ncpus=2,
    )
    test.run()
