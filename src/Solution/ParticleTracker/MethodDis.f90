module MethodDisModule

  use KindModule, only: DP, I4B
  use ConstantsModule, only: DONE, DZERO
  use MethodModule, only: MethodType
  use MethodCellPoolModule
  use CellModule
  use CellDefnModule
  use CellRectModule
  use ParticleModule
  use PrtFmiModule, only: PrtFmiType
  use DisModule, only: DisType
  use TrackModule, only: TrackFileControlType
  use GeomUtilModule, only: get_ijk, get_jk
  implicit none

  private
  public :: MethodDisType
  public :: create_method_dis

  type, extends(MethodType) :: MethodDisType
  contains
    procedure, public :: apply => apply_dis !< apply the method
    procedure, public :: deallocate !< deallocate arrays and scalars
    procedure, public :: load => load_dis !< load the method
    procedure, public :: pass => pass_dis !< pass the particle to the next domain
    procedure, private :: get_top !< get cell top elevation
    procedure, private :: update_flowja !< load intercell mass flows
    procedure, private :: load_particle !< load particle properties
    procedure, private :: load_properties !< load cell properties
    procedure, private :: load_neighbors !< load face neighbors
    procedure, private :: load_faceflows !< load face flows
    procedure, private :: load_boundary_flows !< load boundary flows
    procedure, private :: load_celldefn !< load cell definition from the grid
    procedure, private :: load_cell !< load cell geometry and flows
  end type MethodDisType

contains

  !> @brief Create a new structured grid (DIS) tracking method
  subroutine create_method_dis(method)
    ! -- dummy
    type(MethodDisType), pointer :: method
    ! -- local
    type(CellRectType), pointer :: cell

    allocate (method)
    allocate (method%type)
    call create_cell_rect(cell)
    method%cell => cell
    method%type = "dis"
    method%delegates = .true.
  end subroutine create_method_dis

  !> @brief Destructor the tracking method
  subroutine deallocate (this)
    class(MethodDisType), intent(inout) :: this
    deallocate (this%type)
  end subroutine deallocate

  subroutine load_cell(this, ic, cell)
    ! dummy
    class(MethodDisType), intent(inout) :: this
    integer(I4B), intent(in) :: ic
    type(CellRectType), intent(inout) :: cell
    ! local
    integer(I4B) :: icu
    integer(I4B) :: irow
    integer(I4B) :: jcol
    integer(I4B) :: klay
    real(DP) :: areax
    real(DP) :: areay
    real(DP) :: areaz
    real(DP) :: dx
    real(DP) :: dy
    real(DP) :: dz
    real(DP) :: factor
    real(DP) :: term

    select type (dis => this%fmi%dis)
    type is (DisType)
      icu = dis%get_nodeuser(ic)
      call get_ijk(icu, dis%nrow, dis%ncol, dis%nlay, &
                   irow, jcol, klay)
      dx = dis%delr(jcol)
      dy = dis%delc(irow)
      dz = cell%defn%top - cell%defn%bot
      cell%dx = dx
      cell%dy = dy
      cell%dz = dz
      cell%sinrot = DZERO
      cell%cosrot = DONE
      cell%xOrigin = cell%defn%polyvert(1, 1)
      cell%yOrigin = cell%defn%polyvert(2, 1)
      cell%zOrigin = cell%defn%bot
      cell%ipvOrigin = 1
      areax = dy * dz
      areay = dx * dz
      areaz = dx * dy
      factor = DONE / cell%defn%retfactor
      factor = factor / cell%defn%porosity
      term = factor / areax
      cell%vx1 = cell%defn%faceflow(1) * term
      cell%vx2 = -cell%defn%faceflow(3) * term
      term = factor / areay
      cell%vy1 = cell%defn%faceflow(4) * term
      cell%vy2 = -cell%defn%faceflow(2) * term
      term = factor / areaz
      cell%vz1 = cell%defn%faceflow(6) * term
      cell%vz2 = -cell%defn%faceflow(7) * term
    end select
  end subroutine load_cell

  !> @brief Load the cell geometry and tracking method
  subroutine load_dis(this, particle, next_level, submethod)
    ! -- dummy
    class(MethodDisType), intent(inout) :: this
    type(ParticleType), pointer, intent(inout) :: particle
    integer(I4B), intent(in) :: next_level
    class(MethodType), pointer, intent(inout) :: submethod
    ! -- local
    integer(I4B) :: ic

    select type (cell => this%cell)
    type is (CellRectType)
      ! -- Load cell definition and geometry
      ic = particle%idomain(next_level)
      call this%load_celldefn(ic, cell%defn)
      call this%load_cell(ic, cell)

      ! -- If cell is active but dry, Initialize instant pass-to-bottom method
      if (this%fmi%ibdgwfsat0(ic) == 0) then
        call method_cell_ptb%init( &
          cell=this%cell, &
          trackfilectl=this%trackfilectl, &
          tracktimes=this%tracktimes)
        submethod => method_cell_ptb
      else
        ! -- Otherwise initialize Pollock's method
        call method_cell_plck%init( &
          cell=this%cell, &
          trackfilectl=this%trackfilectl, &
          tracktimes=this%tracktimes)
        submethod => method_cell_plck
      end if
    end select
  end subroutine load_dis

  !> @brief Load cell properties into the particle, including
  ! the z coordinate, entry face, and node and layer numbers.
  subroutine load_particle(this, cell, particle)
    ! dummy
    class(MethodDisType), intent(inout) :: this
    type(CellRectType), pointer, intent(inout) :: cell
    type(ParticleType), pointer, intent(inout) :: particle
    ! local
    integer(I4B) :: ic
    integer(I4B) :: icu
    integer(I4B) :: ilay
    integer(I4B) :: irow
    integer(I4B) :: icol
    integer(I4B) :: inface
    integer(I4B) :: idiag
    integer(I4B) :: inbr
    integer(I4B) :: ipos
    real(DP) :: z
    real(DP) :: zrel
    real(DP) :: topfrom
    real(DP) :: botfrom
    real(DP) :: top
    real(DP) :: bot
    real(DP) :: sat

    select type (dis => this%fmi%dis)
    type is (DisType)
      ! compute and set reduced/user node numbers and layer
      inface = particle%iboundary(2)
      inbr = cell%defn%facenbr(inface)
      idiag = this%fmi%dis%con%ia(cell%defn%icell)
      ipos = idiag + inbr
      ic = dis%con%ja(ipos)
      icu = dis%get_nodeuser(ic)
      call get_ijk(icu, dis%nrow, dis%ncol, dis%nlay, &
                   irow, icol, ilay)
      particle%idomain(2) = ic
      particle%icu = icu
      particle%ilay = ilay

      ! map/set particle entry face
      if (inface .eq. 1) then
        inface = 3
      else if (inface .eq. 2) then
        inface = 4
      else if (inface .eq. 3) then
        inface = 1
      else if (inface .eq. 4) then
        inface = 2
      else if (inface .eq. 6) then
        inface = 7
      else if (inface .eq. 7) then
        inface = 6
      end if
      particle%iboundary(2) = inface

      ! map z between cells
      z = particle%z
      if (inface < 5) then
        topfrom = cell%defn%top
        botfrom = cell%defn%bot
        zrel = (z - botfrom) / (topfrom - botfrom)
        top = dis%top(ic)
        bot = dis%bot(ic)
        sat = this%fmi%gwfsat(ic)
        z = bot + zrel * sat * (top - bot)
      end if
      particle%z = z
    end select

  end subroutine load_particle

  !> @brief Update cell-cell flows of particle mass.
  !! Every particle is currently assigned unit mass.
  subroutine update_flowja(this, cell, particle)
    ! dummy
    class(MethodDisType), intent(inout) :: this
    type(CellRectType), pointer, intent(inout) :: cell
    type(ParticleType), pointer, intent(inout) :: particle
    ! local
    integer(I4B) :: idiag
    integer(I4B) :: inbr
    integer(I4B) :: inface
    integer(I4B) :: ipos

    inface = particle%iboundary(2)
    inbr = cell%defn%facenbr(inface)
    idiag = this%fmi%dis%con%ia(cell%defn%icell)
    ipos = idiag + inbr

    ! -- leaving old cell
    this%flowja(ipos) = this%flowja(ipos) - DONE

    ! -- entering new cell
    this%flowja(this%fmi%dis%con%isym(ipos)) &
      = this%flowja(this%fmi%dis%con%isym(ipos)) + DONE

  end subroutine update_flowja

  !> @brief Pass a particle to the next cell, if there is one
  subroutine pass_dis(this, particle)
    ! dummy
    class(MethodDisType), intent(inout) :: this
    type(ParticleType), pointer, intent(inout) :: particle
    ! local
    type(CellRectType), pointer :: cell

    select type (c => this%cell)
    type is (CellRectType)
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
  end subroutine pass_dis

  !> @brief Apply the method to a particle
  subroutine apply_dis(this, particle, tmax)
    class(MethodDisType), intent(inout) :: this
    type(ParticleType), pointer, intent(inout) :: particle
    real(DP), intent(in) :: tmax

    call this%track(particle, 1, tmax)
  end subroutine apply_dis

  !> @brief Returns a top elevation based on index iatop
  function get_top(this, iatop) result(top)
    class(MethodDisType), intent(inout) :: this
    integer, intent(in) :: iatop
    double precision :: top

    if (iatop .lt. 0) then
      top = this%fmi%dis%top(-iatop)
    else
      top = this%fmi%dis%bot(iatop)
    end if
  end function get_top

  !> @brief Loads cell definition from the grid
  subroutine load_celldefn(this, ic, defn)
    ! -- dummy
    class(MethodDisType), intent(inout) :: this
    integer(I4B), intent(in) :: ic
    type(CellDefnType), pointer, intent(inout) :: defn

    ! -- Load basic cell properties
    call this%load_properties(ic, defn)

    ! -- Load cell polygon vertices
    call this%fmi%dis%get_polyverts( &
      defn%icell, &
      defn%polyvert, &
      closed=.true.)

    ! -- Load cell face neighbors
    call this%load_neighbors(defn)

    ! -- Load 180 degree face indicators
    defn%ispv180(1:defn%npolyverts + 1) = .false.

    ! -- Load face flows (assumes face neighbors already loaded)
    call this%load_faceflows(defn)

  end subroutine load_celldefn

  subroutine load_properties(this, ic, defn)
    ! -- dummy
    class(MethodDisType), intent(inout) :: this
    integer(I4B), intent(in) :: ic
    type(CellDefnType), pointer, intent(inout) :: defn

    defn%icell = ic
    defn%npolyverts = 4 ! rectangular cell always has 4 vertices
    defn%iatop = get_iatop(this%fmi%dis%get_ncpl(), &
                           this%fmi%dis%get_nodeuser(ic))
    defn%top = this%fmi%dis%bot(ic) + &
               this%fmi%gwfsat(ic) * &
               (this%fmi%dis%top(ic) - this%fmi%dis%bot(ic))
    defn%bot = this%fmi%dis%bot(ic)
    defn%sat = this%fmi%gwfsat(ic)
    defn%porosity = this%porosity(ic)
    defn%retfactor = this%retfactor(ic)
    defn%izone = this%izone(ic)
    defn%can_be_rect = .true.
    defn%can_be_quad = .false.

  end subroutine load_properties

  !> @brief Loads face neighbors to cell definition from the grid.
  !! Assumes cell index and number of vertices are already loaded.
  subroutine load_neighbors(this, defn)
    ! -- dummy
    class(MethodDisType), intent(inout) :: this
    type(CellDefnType), pointer, intent(inout) :: defn
    ! -- local
    integer(I4B) :: ic1
    integer(I4B) :: ic2
    integer(I4B) :: icu1
    integer(I4B) :: icu2
    integer(I4B) :: j1
    integer(I4B) :: iloc
    integer(I4B) :: ipos
    integer(I4B) :: irow1
    integer(I4B) :: irow2
    integer(I4B) :: jcol1
    integer(I4B) :: jcol2
    integer(I4B) :: klay1
    integer(I4B) :: klay2
    integer(I4B) :: iedgeface

    select type (dis => this%fmi%dis)
    type is (DisType)
      ! -- Load face neighbors
      defn%facenbr = 0
      ic1 = defn%icell
      icu1 = dis%get_nodeuser(ic1)
      call get_ijk(icu1, dis%nrow, dis%ncol, dis%nlay, &
                   irow1, jcol1, klay1)
      call get_jk(icu1, dis%get_ncpl(), dis%nlay, j1, klay1)
      do iloc = 1, dis%con%ia(ic1 + 1) - dis%con%ia(ic1) - 1
        ipos = dis%con%ia(ic1) + iloc
        ! mask could become relevant if PRT uses interface model
        if (dis%con%mask(ipos) == 0) cycle
        ic2 = dis%con%ja(ipos)
        icu2 = dis%get_nodeuser(ic2)
        call get_ijk(icu2, dis%nrow, dis%ncol, dis%nlay, &
                     irow2, jcol2, klay2)
        if (klay2 == klay1) then
          ! -- Edge (polygon) face neighbor
          if (irow2 > irow1) then
            ! Neighbor to the S
            iedgeface = 4
          else if (jcol2 > jcol1) then
            ! Neighbor to the E
            iedgeface = 3
          else if (irow2 < irow1) then
            ! Neighbor to the N
            iedgeface = 2
          else
            ! Neighbor to the W
            iedgeface = 1
          end if
          defn%facenbr(iedgeface) = int(iloc, 1)
        else if (klay2 > klay1) then
          ! -- Bottom face neighbor
          defn%facenbr(defn%npolyverts + 2) = int(iloc, 1)
        else
          ! -- Top face neighbor
          defn%facenbr(defn%npolyverts + 3) = int(iloc, 1)
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
    class(MethodDisType), intent(inout) :: this
    type(CellDefnType), intent(inout) :: defn
    ! -- local
    integer(I4B) :: m
    integer(I4B) :: n
    real(DP) :: q

    ! -- Load face flows, including boundary flows. As with cell verts,
    !    the face flow array wraps around. Top and bottom flows make up
    !    the last two elements, respectively, for size npolyverts + 3.
    !    If there is no flow through any face, set a no-exit-face flag.
    defn%faceflow = DZERO
    defn%inoexitface = 1
    call this%load_boundary_flows(defn)
    do m = 1, defn%npolyverts + 3
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

  !> @brief Add boundary flows to the cell definition faceflow array.
  !! Assumes cell index and number of vertices are already loaded.
  subroutine load_boundary_flows(this, defn)
    ! -- dummy
    class(MethodDisType), intent(inout) :: this
    type(CellDefnType), intent(inout) :: defn
    ! -- local
    integer(I4B) :: ioffset

    ioffset = (defn%icell - 1) * MAX_POLY_CELLS
    defn%faceflow(1) = defn%faceflow(1) + &
                       this%fmi%BoundaryFlows(ioffset + 1)
    defn%faceflow(2) = defn%faceflow(2) + &
                       this%fmi%BoundaryFlows(ioffset + 2)
    defn%faceflow(3) = defn%faceflow(3) + &
                       this%fmi%BoundaryFlows(ioffset + 3)
    defn%faceflow(4) = defn%faceflow(4) + &
                       this%fmi%BoundaryFlows(ioffset + 4)
    defn%faceflow(5) = defn%faceflow(1)
    defn%faceflow(6) = defn%faceflow(6) + &
                       this%fmi%BoundaryFlows(ioffset + 9)
    defn%faceflow(7) = defn%faceflow(7) + &
                       this%fmi%BoundaryFlows(ioffset + 10)
  end subroutine load_boundary_flows

end module MethodDisModule
