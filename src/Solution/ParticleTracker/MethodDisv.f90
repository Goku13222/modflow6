module MethodDisvModule

  use KindModule, only: DP, I4B, LGP
  use ErrorUtilModule, only: pstop
  use ConstantsModule, only: DONE, DZERO
  use MethodModule, only: MethodType
  use MethodCellPoolModule
  use CellModule, only: MAX_POLY_CELLS
  use CellDefnModule
  use CellPolyModule
  use ParticleModule
  use PrtFmiModule, only: PrtFmiType
  use DisvModule, only: DisvType
  use ArrayHandlersModule, only: ExpandArray
  use TrackModule, only: TrackFileControlType
  use GeomUtilModule, only: get_jk, shared_face
  implicit none

  private
  public :: MethodDisvType
  public :: create_method_disv

  type, extends(MethodType) :: MethodDisvType
    type(CellDefnType), pointer :: neighbor => null() !< ptr to a neighbor defn
  contains
    procedure, public :: apply => apply_disv !< apply the DISV-grid method
    procedure, public :: deallocate !< deallocate arrays and scalars
    procedure, public :: load => load_disv !< load the cell method
    procedure, public :: load_cell_defn !< load cell definition from the grid
    procedure, public :: pass => pass_disv !< pass the particle to the next cell
    procedure, private :: map_neighbor !< map a location on the cell face to the shared face of a neighbor
    procedure, private :: update_flowja !< update intercell mass flows
    procedure, private :: load_particle !< load particle properties
    procedure, private :: load_properties !< load cell properties
    procedure, private :: load_polygon !< load cell polygon
    procedure, private :: load_neighbors !< load face neighbors
    procedure, private :: load_indicators !< load 180-degree vertex indicator
    procedure, private :: load_faceflows !< load flows
    procedure, private :: load_boundary_flows_to_defn_rect !< load boundary flows to a rectangular cell
    procedure, private :: load_boundary_flows_to_defn_rect_quad !< load boundary flows to a rectangular-quad cell
    procedure, private :: load_boundary_flows_to_defn_poly !< load boundary flows to a polygonal cell
  end type MethodDisvType

contains

  !> @brief Create a new vertex grid (DISV) tracking method
  subroutine create_method_disv(method)
    ! -- dummy
    type(MethodDisvType), pointer :: method
    ! -- local
    type(CellPolyType), pointer :: cell

    allocate (method)
    allocate (method%type)
    call create_cell_poly(cell)
    method%cell => cell
    method%type = "disv"
    method%delegates = .true.
    call create_defn(method%neighbor)
  end subroutine create_method_disv

  !> @brief Destroy the tracking method
  subroutine deallocate (this)
    class(MethodDisvType), intent(inout) :: this
    deallocate (this%type)
  end subroutine deallocate

  !> @brief Load the cell and the tracking method
  subroutine load_disv(this, particle, next_level, submethod)
    use CellModule
    use CellRectModule
    use CellRectQuadModule
    use CellUtilModule
    ! -- dummy
    class(MethodDisvType), intent(inout) :: this
    type(ParticleType), pointer, intent(inout) :: particle
    integer(I4B), intent(in) :: next_level
    class(MethodType), pointer, intent(inout) :: submethod
    ! -- local
    integer(I4B) :: ic
    class(CellType), pointer :: base
    type(CellRectType), pointer :: rect
    type(CellRectQuadType), pointer :: quad

    select type (cell => this%cell)
    type is (CellPolyType)
      ! load cell definition
      ic = particle%idomain(next_level)
      call this%load_cell_defn(ic, cell%defn)
      if (this%fmi%ibdgwfsat0(ic) == 0) then
        ! -- Cell is active but dry, so select and initialize pass-to-bottom
        ! -- cell method and set cell method pointer
        call method_cell_ptb%init( &
          cell=this%cell, &
          trackfilectl=this%trackfilectl, &
          tracktimes=this%tracktimes)
        submethod => method_cell_ptb
      else
        ! -- Select and initialize cell method and set cell method pointer
        if (particle%ifrctrn > 0) then
          call method_cell_tern%init( &
            cell=this%cell, &
            trackfilectl=this%trackfilectl, &
            tracktimes=this%tracktimes)
          submethod => method_cell_tern
        else if (cell%defn%can_be_rect) then
          call cell_poly_to_rect(cell, rect)
          base => rect
          call method_cell_plck%init( &
            cell=base, &
            trackfilectl=this%trackfilectl, &
            tracktimes=this%tracktimes)
          submethod => method_cell_plck
        else if (cell%defn%can_be_quad) then
          call cell_poly_to_quad(cell, quad)
          base => quad
          call method_cell_quad%init( &
            cell=base, &
            trackfilectl=this%trackfilectl, &
            tracktimes=this%tracktimes)
          submethod => method_cell_quad
        else
          call method_cell_tern%init( &
            cell=this%cell, &
            trackfilectl=this%trackfilectl, &
            tracktimes=this%tracktimes)
          submethod => method_cell_tern
        end if
      end if
    end select
  end subroutine load_disv

  subroutine load_particle(this, cell, particle)
    ! modules
    use DisvModule, only: DisvType
    ! dummy
    class(MethodDisvType), intent(inout) :: this
    type(CellPolyType), pointer, intent(inout) :: cell
    type(ParticleType), pointer, intent(inout) :: particle
    ! local
    integer(I4B) :: inface
    integer(I4B) :: ipos
    integer(I4B) :: ic
    integer(I4B) :: icu
    integer(I4B) :: inbr
    integer(I4B) :: idiag
    integer(I4B) :: icpl
    integer(I4B) :: ilay
    real(DP) :: z

    select type (dis => this%fmi%dis)
    type is (DisvType)
      ! compute and set reduced/user node numbers and layer
      inface = particle%iboundary(2)
      idiag = dis%con%ia(cell%defn%icell)
      inbr = cell%defn%facenbr(inface)
      ipos = idiag + inbr
      ic = dis%con%ja(ipos)
      icu = dis%get_nodeuser(ic)
      call get_jk(icu, dis%ncpl, dis%nlay, icpl, ilay)
      particle%idomain(2) = ic
      particle%icu = icu
      particle%ilay = ilay

      ! map/set particle entry face and z coordinate
      z = particle%z
      call this%map_neighbor(cell%defn, inface, z)
      particle%iboundary(2) = inface
      particle%idomain(3:) = 0
      particle%iboundary(3:) = 0
      particle%z = z
    end select

  end subroutine

  subroutine update_flowja(this, cell, particle)
    ! dummy
    class(MethodDisvType), intent(inout) :: this
    type(CellPolyType), pointer, intent(inout) :: cell
    type(ParticleType), pointer, intent(inout) :: particle
    ! local
    integer(I4B) :: inbr
    integer(I4B) :: idiag
    integer(I4B) :: ipos

    idiag = this%fmi%dis%con%ia(cell%defn%icell)
    inbr = cell%defn%facenbr(particle%iboundary(2))
    ipos = idiag + inbr

    ! leaving old cell
    this%flowja(ipos) = this%flowja(ipos) - DONE

    ! entering new cell
    this%flowja(this%fmi%dis%con%isym(ipos)) &
      = this%flowja(this%fmi%dis%con%isym(ipos)) + DONE

  end subroutine update_flowja

  !> @brief Pass a particle to the next cell, if there is one
  subroutine pass_disv(this, particle)
    ! dummy
    class(MethodDisvType), intent(inout) :: this
    type(ParticleType), pointer, intent(inout) :: particle
    ! local
    type(CellPolyType), pointer :: cell

    select type (c => this%cell)
    type is (CellPolyType)
      cell => c
      ! If the entry face has no neighbors it's a
      ! boundary face, so terminate the particle.
      ! todo AMP: reconsider when multiple models supported
      if (cell%defn%facenbr(particle%iboundary(2)) .eq. 0) then
        particle%istatus = 2
        particle%advancing = .false.
        call this%save(particle, reason=3)
      else
        ! Otherwise, load cell properties into the
        ! particle and update intercell mass flows
        call this%load_particle(cell, particle)
        call this%update_flowja(cell, particle)
      end if
    end select
  end subroutine pass_disv

  !> @brief Map location on cell face to shared cell face of neighbor
  subroutine map_neighbor(this, defn, inface, z)
    ! dummy
    class(MethodDisvType), intent(inout) :: this
    type(CellDefnType), pointer, intent(inout) :: defn
    integer(I4B), intent(inout) :: inface
    double precision, intent(inout) :: z
    ! local
    integer(I4B) :: icin
    integer(I4B) :: npolyvertsin
    integer(I4B) :: ic
    integer(I4B) :: npolyverts
    integer(I4B) :: inbr
    integer(I4B) :: inbrnbr
    integer(I4B) :: j
    integer(I4B) :: m
    real(DP) :: zrel
    real(DP) :: topfrom
    real(DP) :: botfrom
    real(DP) :: top
    real(DP) :: bot
    real(DP) :: sat

    ! -- Map to shared cell face of neighbor
    inbr = defn%facenbr(inface)
    if (inbr .eq. 0) then
      ! -- Exterior face; no neighbor to map to
      ! todo AMP: reconsider when multiple models allowed
      inface = -1
    else
      ! -- Load definition for neighbor cell (neighbor with shared face)
      icin = defn%icell
      j = this%fmi%dis%con%ia(icin)
      ic = this%fmi%dis%con%ja(j + inbr)
      call this%load_cell_defn(ic, this%neighbor)

      npolyvertsin = defn%npolyverts
      npolyverts = this%neighbor%npolyverts
      if (inface .eq. npolyvertsin + 2) then
        ! -- Exits through bot, enters through top
        inface = npolyverts + 3
      else if (inface .eq. npolyvertsin + 3) then
        ! -- Exits through top, enters through bot
        inface = npolyverts + 2
      else
        ! -- Exits and enters through shared polygon face
        j = this%fmi%dis%con%ia(ic)
        do m = 1, npolyverts + 3
          inbrnbr = this%neighbor%facenbr(m)
          if (this%fmi%dis%con%ja(j + inbrnbr) .eq. icin) then
            inface = m
            exit
          end if
        end do
        ! -- Map z between cells
        topfrom = defn%top
        botfrom = defn%bot
        zrel = (z - botfrom) / (topfrom - botfrom)
        top = this%fmi%dis%top(ic)
        bot = this%fmi%dis%bot(ic)
        sat = this%fmi%gwfsat(ic)
        z = bot + zrel * sat * (top - bot)
      end if
    end if
  end subroutine map_neighbor

  !> @brief Apply the DISV-grid method
  subroutine apply_disv(this, particle, tmax)
    class(MethodDisvType), intent(inout) :: this
    type(ParticleType), pointer, intent(inout) :: particle
    real(DP), intent(in) :: tmax
    call this%track(particle, 1, tmax)
  end subroutine apply_disv

  !> @brief Load cell definition from the grid
  subroutine load_cell_defn(this, ic, defn)
    ! -- dummy
    class(MethodDisvType), intent(inout) :: this
    integer(I4B), intent(in) :: ic
    type(CellDefnType), pointer, intent(inout) :: defn

    ! -- Load basic cell properties
    call this%load_properties(ic, defn)

    ! -- Load polygon vertices
    call this%load_polygon(defn)

    ! -- Load face neighbors
    call this%load_neighbors(defn)

    ! -- Load 180-degree indicator
    call this%load_indicators(defn)

    ! -- Load flows (assumes face neighbors already loaded)
    call this%load_faceflows(defn)
  end subroutine load_cell_defn

  !> @brief Loads cell properties to cell definition from the grid.
  subroutine load_properties(this, ic, defn)
    ! dummy
    class(MethodDisvType), intent(inout) :: this
    integer(I4B), intent(in) :: ic
    type(CellDefnType), pointer, intent(inout) :: defn
    ! local
    real(DP) :: top
    real(DP) :: bot
    real(DP) :: sat

    defn%icell = ic
    defn%iatop = get_iatop(this%fmi%dis%get_ncpl(), &
                           this%fmi%dis%get_nodeuser(ic))
    top = this%fmi%dis%top(ic)
    bot = this%fmi%dis%bot(ic)
    sat = this%fmi%gwfsat(ic)
    top = bot + sat * (top - bot)
    defn%top = top
    defn%bot = bot
    defn%sat = sat
    defn%porosity = this%porosity(ic)
    defn%retfactor = this%retfactor(ic)
    defn%izone = this%izone(ic)

  end subroutine load_properties

  subroutine load_polygon(this, defn)
    ! dummy
    class(MethodDisvType), intent(inout) :: this
    type(CellDefnType), pointer, intent(inout) :: defn

    call this%fmi%dis%get_polyverts( &
      defn%icell, &
      defn%polyvert, &
      closed=.true.)
    defn%npolyverts = size(defn%polyvert, dim=2) - 1

  end subroutine load_polygon

  !> @brief Loads face neighbors to cell definition from the grid
  !! Assumes cell index and number of vertices are already loaded.
  subroutine load_neighbors(this, defn)
    ! -- dummy
    class(MethodDisvType), intent(inout) :: this
    type(CellDefnType), pointer, intent(inout) :: defn
    ! -- local
    integer(I4B) :: ic1
    integer(I4B) :: ic2
    integer(I4B) :: icu1
    integer(I4B) :: icu2
    integer(I4B) :: j1
    integer(I4B) :: j2
    integer(I4B) :: k1
    integer(I4B) :: k2
    integer(I4B) :: iloc
    integer(I4B) :: ipos
    integer(I4B) :: istart1
    integer(I4B) :: istart2
    integer(I4B) :: istop1
    integer(I4B) :: istop2
    integer(I4B) :: isharedface
    integer(I4B) :: ncpl
    integer(I4B) :: nfaces
    integer(I4B) :: nslots

    ! -- expand facenbr array if needed
    nfaces = defn%npolyverts + 3
    nslots = size(defn%facenbr)
    if (nslots < nfaces) call ExpandArray(defn%facenbr, nfaces - nslots)

    select type (dis => this%fmi%dis)
    type is (DisvType)
      ! -- Load face neighbors.
      defn%facenbr = 0
      ic1 = defn%icell
      icu1 = dis%get_nodeuser(ic1)
      ncpl = dis%get_ncpl()
      call get_jk(icu1, ncpl, dis%nlay, j1, k1)
      istart1 = dis%iavert(j1)
      istop1 = dis%iavert(j1 + 1) - 1
      do iloc = 1, dis%con%ia(ic1 + 1) - dis%con%ia(ic1) - 1
        ipos = dis%con%ia(ic1) + iloc
        ! mask could become relevant if PRT uses interface model
        if (dis%con%mask(ipos) == 0) cycle
        ic2 = dis%con%ja(ipos)
        icu2 = dis%get_nodeuser(ic2)
        call get_jk(icu2, ncpl, dis%nlay, j2, k2)
        istart2 = dis%iavert(j2)
        istop2 = dis%iavert(j2 + 1) - 1
        call shared_face(dis%javert(istart1:istop1), &
                         dis%javert(istart2:istop2), &
                         isharedface)
        if (isharedface /= 0) then
          ! -- Edge (polygon) face neighbor
          defn%facenbr(isharedface) = int(iloc, 1)
        else
          if (k2 > k1) then
            ! -- Bottom face neighbor
            defn%facenbr(defn%npolyverts + 2) = int(iloc, 1)
          else if (k2 < k1) then
            ! -- Top face neighbor
            defn%facenbr(defn%npolyverts + 3) = int(iloc, 1)
          else
            call pstop(1, "k2 should be <> k1, since no shared edge face")
          end if
        end if
      end do
    end select
    ! -- List of edge (polygon) faces wraps around
    defn%facenbr(defn%npolyverts + 1) = defn%facenbr(1)

  end subroutine load_neighbors

  !> @brief Load flows into the cell definition.
  !! These include face flows and net distributed flows.
  !! Assumes cell index and number of vertices are already loaded.
  subroutine load_faceflows(this, defn)
    ! -- dummy
    class(MethodDisvType), intent(inout) :: this
    type(CellDefnType), intent(inout) :: defn
    ! -- local
    integer(I4B) :: nfaces
    integer(I4B) :: nslots
    integer(I4B) :: m
    integer(I4B) :: n
    real(DP) :: q

    ! -- expand faceflow array if needed
    nfaces = defn%npolyverts + 3
    nslots = size(defn%faceflow)
    if (nslots < nfaces) call ExpandArray(defn%faceflow, nfaces - nslots)

    ! -- Load face flows, including boundary flows. As with cell verts,
    !    the face flow array wraps around. Top and bottom flows make up
    !    the last two elements, respectively, for size npolyverts + 3.
    !    If there is no flow through any face, set a no-exit-face flag.
    defn%faceflow = DZERO
    defn%inoexitface = 1
    call this%load_boundary_flows_to_defn_poly(defn)
    do m = 1, nfaces
      n = defn%facenbr(m)
      if (n > 0) then
        q = this%fmi%gwfflowja(this%fmi%dis%con%ia(defn%icell) + n)
        defn%faceflow(m) = q
      end if
      if (defn%faceflow(m) < DZERO) defn%inoexitface = 0
    end do

    ! -- Add up net distributed flow
    defn%distflow = this%fmi%SourceFlows(defn%icell) + &
                    this%fmi%SinkFlows(defn%icell) + &
                    this%fmi%StorageFlows(defn%icell)

    ! -- Set weak sink flag
    if (this%fmi%SinkFlows(defn%icell) .ne. DZERO) then
      defn%iweaksink = 1
    else
      defn%iweaksink = 0
    end if

  end subroutine load_faceflows

  !> @brief Load boundary flows from the grid into a rectangular cell.
  !! Assumes cell index and number of vertices are already loaded.
  subroutine load_boundary_flows_to_defn_rect(this, defn)
    ! -- dummy
    class(MethodDisvType), intent(inout) :: this
    type(CellDefnType), intent(inout) :: defn
    ! -- local
    integer(I4B) :: ioffset

    ! assignment of BoundaryFlows to faceflow below assumes clockwise
    ! ordering of faces, with face 1 being the "western" face
    ioffset = (defn%icell - 1) * 10
    defn%faceflow(1) = defn%faceflow(1) + &
                       this%fmi%BoundaryFlows(ioffset + 4)
    defn%faceflow(2) = defn%faceflow(2) + &
                       this%fmi%BoundaryFlows(ioffset + 2)
    defn%faceflow(3) = defn%faceflow(3) + &
                       this%fmi%BoundaryFlows(ioffset + 3)
    defn%faceflow(4) = defn%faceflow(4) + &
                       this%fmi%BoundaryFlows(ioffset + 1)
    defn%faceflow(5) = defn%faceflow(1)
    defn%faceflow(6) = defn%faceflow(6) + &
                       this%fmi%BoundaryFlows(ioffset + 9)
    defn%faceflow(7) = defn%faceflow(7) + &
                       this%fmi%BoundaryFlows(ioffset + 10)

  end subroutine load_boundary_flows_to_defn_rect

  !> @brief Load boundary flows from the grid into rectangular quadcell.
  !! Assumes cell index and number of vertices are already loaded.
  subroutine load_boundary_flows_to_defn_rect_quad(this, defn)
    ! -- dummy
    class(MethodDisvType), intent(inout) :: this
    type(CellDefnType), intent(inout) :: defn
    ! -- local
    integer(I4B) :: m
    integer(I4B) :: n
    integer(I4B) :: nn
    integer(I4B) :: ioffset
    integer(I4B) :: nbf
    integer(I4B) :: m1
    integer(I4B) :: m2
    integer(I4B) :: mdiff
    real(DP) :: qbf
    integer(I4B) :: irectvert(5)

    ioffset = (defn%icell - 1) * 10

    ! -- Polygon faces in positions 1 through npolyverts
    do n = 1, 4
      if (n .eq. 2) then
        nbf = 4
      else if (n .eq. 4) then
        nbf = 1
      else
        nbf = n
      end if
      qbf = this%fmi%BoundaryFlows(ioffset + nbf)
      nn = 0
      do m = 1, defn%npolyverts
        if (.not. defn%ispv180(m)) then
          nn = nn + 1
          irectvert(nn) = m
        end if
      end do
      irectvert(5) = irectvert(1)
      m1 = irectvert(n)
      m2 = irectvert(n + 1)
      if (m2 .lt. m1) m2 = m2 + defn%npolyverts
      mdiff = m2 - m1
      if (mdiff .eq. 1) then
        ! -- Assign BoundaryFlow to corresponding polygon face
        defn%faceflow(m1) = defn%faceflow(m1) + qbf
      else
        ! -- Split BoundaryFlow between two faces on quad-refined edge
        qbf = 5d-1 * qbf
        defn%faceflow(m1) = defn%faceflow(m1) + qbf
        defn%faceflow(m1 + 1) = defn%faceflow(m1 + 1) + qbf
      end if
    end do
    ! -- Wrap around to 1 in position npolyverts+1
    m = defn%npolyverts + 1
    defn%faceflow(m) = defn%faceflow(1)
    ! -- Bottom in position npolyverts+2
    m = m + 1
    defn%faceflow(m) = defn%faceflow(m) + &
                       this%fmi%BoundaryFlows(ioffset + 9)
    ! -- Top in position npolyverts+3
    m = m + 1
    defn%faceflow(m) = defn%faceflow(m) + &
                       this%fmi%BoundaryFlows(ioffset + 10)

  end subroutine load_boundary_flows_to_defn_rect_quad

  !> @brief Load boundary flows from the grid into a polygonal cell.
  !! Assumes cell index and number of vertices are already loaded.
  subroutine load_boundary_flows_to_defn_poly(this, defn)
    ! -- dummy
    class(MethodDisvType), intent(inout) :: this
    type(CellDefnType), intent(inout) :: defn
    ! -- local
    integer(I4B) :: ic
    integer(I4B) :: npolyverts
    integer(I4B) :: ioffset
    integer(I4B) :: iv

    ic = defn%icell
    npolyverts = defn%npolyverts

    ioffset = (ic - 1) * MAX_POLY_CELLS
    do iv = 1, npolyverts
      defn%faceflow(iv) = &
        defn%faceflow(iv) + &
        this%fmi%BoundaryFlows(ioffset + iv)
    end do
    defn%faceflow(npolyverts + 1) = defn%faceflow(1)
    defn%faceflow(npolyverts + 2) = &
      defn%faceflow(npolyverts + 2) + &
      this%fmi%BoundaryFlows(ioffset + MAX_POLY_CELLS - 1)
    defn%faceflow(npolyverts + 3) = &
      defn%faceflow(npolyverts + 3) + &
      this%fmi%BoundaryFlows(ioffset + MAX_POLY_CELLS)

  end subroutine load_boundary_flows_to_defn_poly

  !> @brief Load 180-degree vertex indicator array and set flags
  !! indicating how cell can be represented.
  !! Assumes cell index and number of vertices are already loaded.
  subroutine load_indicators(this, defn)
    ! -- dummy
    class(MethodDisvType), intent(inout) :: this
    type(CellDefnType), pointer, intent(inout) :: defn
    ! -- local
    integer(I4B) :: npolyverts
    integer(I4B) :: m
    integer(I4B) :: m0
    integer(I4B) :: m1
    integer(I4B) :: m2
    integer(I4B) :: ic
    integer(I4B) :: num90
    integer(I4B) :: num180
    real(DP) :: x0
    real(DP) :: y0
    real(DP) :: x1
    real(DP) :: y1
    real(DP) :: x2
    real(DP) :: y2
    real(DP) :: epsang
    real(DP) :: s0x
    real(DP) :: s0y
    real(DP) :: &
      s0mag, s2x, s2y, s2mag, sinang, cosang, dotprod
    logical(LGP) last180

    ic = defn%icell
    npolyverts = defn%npolyverts

    ! -- expand ispv180 array if needed
    if (size(defn%ispv180) < npolyverts + 3) &
      call ExpandArray(defn%ispv180, npolyverts + 1)

    ! -- Load 180-degree indicator.
    ! -- Also, set flags that indicate how cell can be represented.
    defn%ispv180(1:npolyverts + 1) = .false.
    defn%can_be_rect = .false.
    defn%can_be_quad = .false.
    epsang = 1d-5
    num90 = 0
    num180 = 0
    last180 = .false.
    ! assumes non-self-intersecting polygon
    do m = 1, npolyverts
      m1 = m
      if (m1 .eq. 1) then
        m0 = npolyverts
        m2 = 2
      else if (m1 .eq. npolyverts) then
        m0 = npolyverts - 1
        m2 = 1
      else
        m0 = m1 - 1
        m2 = m1 + 1
      end if
      x0 = defn%polyvert(1, m0)
      y0 = defn%polyvert(2, m0)
      x1 = defn%polyvert(1, m1)
      y1 = defn%polyvert(2, m1)
      x2 = defn%polyvert(1, m2)
      y2 = defn%polyvert(2, m2)
      s0x = x0 - x1
      s0y = y0 - y1
      s0mag = dsqrt(s0x * s0x + s0y * s0y)
      s2x = x2 - x1
      s2y = y2 - y1
      s2mag = dsqrt(s2x * s2x + s2y * s2y)
      sinang = (s0x * s2y - s0y * s2x) / (s0mag * s2mag)
      cosang = dsqrt(dabs(DONE - (sinang * sinang)))
      if (dabs(sinang) .lt. epsang) then
        dotprod = s0x * s2x + s0y * s2y
        if (dotprod .lt. DZERO) then
          num180 = num180 + 1
          last180 = .true.
          defn%ispv180(m) = .true.
        end if
      else
        if (dabs(cosang) .lt. epsang) num90 = num90 + 1
        last180 = .false.
      end if
    end do

    ! -- List of 180-degree indicators wraps around for convenience
    defn%ispv180(npolyverts + 1) = defn%ispv180(1)

    if (num90 .eq. 4) then
      if (num180 .eq. 0) then
        defn%can_be_rect = .true.
      else
        defn%can_be_quad = .true.
      end if
    end if

  end subroutine load_indicators

end module MethodDisvModule
