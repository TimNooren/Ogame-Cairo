%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math_cmp import is_le
from starkware.starknet.common.syscalls import get_block_timestamp
from starkware.cairo.common.uint256 import Uint256
from contracts.token.erc20.interfaces.IERC20 import IERC20
from contracts.utils.library import (
    _planet_to_owner, _planets, Planet, MineLevels, MineStorage, Energy, Facilities,
    erc20_metal_address, erc20_crystal_address, erc20_deuterium_address, FALSE)
from contracts.utils.Formulas import (
    _consumption, _consumption_deuterium, formulas_metal_mine, formulas_crystal_mine,
    formulas_deuterium_mine, formulas_solar_plant, formulas_production_scaler,
    _solar_production_formula)

func _calculate_available_resources{
        syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(caller : felt) -> (
        metal : felt, crystal : felt, deuterium : felt):
    alloc_locals
    let (planet_id) = _planet_to_owner.read(caller)
    let (planet) = _planets.read(planet_id)
    let time_start = planet.timer
    let metal_level = planet.mines.metal
    let crystal_level = planet.mines.crystal
    let deuterium_level = planet.mines.deuterium
    # Calculate energy requirerments.
    let (energy_required_metal) = _consumption(metal_level)
    let (energy_required_crystal) = _consumption(crystal_level)
    let (energy_required_deuterium) = _consumption_deuterium(deuterium_level)
    let total_energy_required = energy_required_metal + energy_required_crystal + energy_required_deuterium
    let solar_plant_level = planet.energy.solar_plant
    let (energy_available) = formulas_solar_plant(solar_plant_level)

    let (enough_energy) = is_le(total_energy_required, energy_available)
    # Calculate amount of resources produced.
    let (metal_produced) = formulas_metal_mine(last_timestamp=time_start, mine_level=metal_level)
    let (crystal_produced) = formulas_crystal_mine(
        last_timestamp=time_start, mine_level=crystal_level)
    let (deuterium_produced) = formulas_deuterium_mine(
        last_timestamp=time_start, mine_level=deuterium_level)
    # If energy available < than energy required scale down amount produced.
    if enough_energy == FALSE:
        let (actual_metal, actual_crystal, actual_deuterium) = formulas_production_scaler(
            net_metal=metal_produced,
            net_crystal=crystal_produced,
            net_deuterium=deuterium_produced,
            energy_required=total_energy_required,
            energy_available=energy_available)
        let metal = planet.storage.metal + actual_metal
        let crystal = planet.storage.crystal + actual_crystal
        let deuterium = planet.storage.deuterium + actual_deuterium
        return (metal, crystal, deuterium)
    else:
        let metal = planet.storage.metal + metal_produced
        let crystal = planet.storage.crystal + crystal_produced
        let deuterium = planet.storage.deuterium + deuterium_produced
        return (metal, crystal, deuterium)
    end
end

func _collect_resources{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        caller : felt):
    alloc_locals
    let (planet_id) = _planet_to_owner.read(caller)
    let (planet) = _planets.read(planet_id)
    let time_start = planet.timer
    let metal_level = planet.mines.metal
    let crystal_level = planet.mines.crystal
    let deuterium_level = planet.mines.deuterium
    # Calculate energy requirerments.
    let (energy_required_metal) = _consumption(metal_level)
    let (energy_required_crystal) = _consumption(crystal_level)
    let (energy_required_deuterium) = _consumption_deuterium(deuterium_level)
    let total_energy_required = energy_required_metal + energy_required_crystal + energy_required_deuterium
    let solar_plant_level = planet.energy.solar_plant
    let (energy_available) = formulas_solar_plant(solar_plant_level)

    let (enough_energy) = is_le(total_energy_required, energy_available)
    # Calculate amount of resources produced.
    let (metal_produced) = formulas_metal_mine(last_timestamp=time_start, mine_level=metal_level)
    let (crystal_produced) = formulas_crystal_mine(
        last_timestamp=time_start, mine_level=crystal_level)
    let (deuterium_produced) = formulas_deuterium_mine(
        last_timestamp=time_start, mine_level=deuterium_level)
    # If energy available < than energy required scale down amount produced.
    if enough_energy == FALSE:
        let (actual_metal, actual_crystal, actual_deuterium) = formulas_production_scaler(
            net_metal=metal_produced,
            net_crystal=crystal_produced,
            net_deuterium=deuterium_produced,
            energy_required=total_energy_required,
            energy_available=energy_available)
        let (time_now) = get_block_timestamp()
        let updated_planet = Planet(
            MineLevels(metal=planet.mines.metal, crystal=planet.mines.crystal, deuterium=planet.mines.deuterium),
            MineStorage(metal=planet.storage.metal + actual_metal,
            crystal=planet.storage.crystal + actual_crystal,
            deuterium=planet.storage.deuterium + actual_deuterium),
            Energy(solar_plant=planet.energy.solar_plant),
            Facilities(robot_factory=planet.facilities.robot_factory),
            timer=time_now)
        _planets.write(planet_id, updated_planet)
        # Update ERC20 contract for resources
        _receive_resources_erc20(
            to=caller,
            metal_amount=actual_metal,
            crystal_amount=actual_crystal,
            deuterium_amount=actual_deuterium)
    else:
        let (time_now) = get_block_timestamp()
        let updated_planet = Planet(
            MineLevels(metal=planet.mines.metal, crystal=planet.mines.crystal, deuterium=planet.mines.deuterium),
            MineStorage(metal=planet.storage.metal + metal_produced,
            crystal=planet.storage.crystal + crystal_produced,
            deuterium=planet.storage.deuterium + deuterium_produced),
            Energy(solar_plant=planet.energy.solar_plant),
            Facilities(robot_factory=planet.facilities.robot_factory),
            timer=time_now)
        _planets.write(planet_id, updated_planet)
        # Update ERC20 contract for resources
        _receive_resources_erc20(
            to=caller,
            metal_amount=metal_produced,
            crystal_amount=crystal_produced,
            deuterium_amount=deuterium_produced)
    end
    return ()
end

# Updates the ERC20 resources contract
func _receive_resources_erc20{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        to : felt, metal_amount : felt, crystal_amount : felt, deuterium_amount : felt):
    let (metal_address) = erc20_metal_address.read()
    let (crystal_address) = erc20_crystal_address.read()
    let (deuterium_address) = erc20_deuterium_address.read()
    let metal = Uint256(metal_amount * 10, 0)
    let crystal = Uint256(crystal_amount * 10, 0)
    let deuterium = Uint256(deuterium_amount * 10, 0)
    IERC20.mint(metal_address, to, metal)
    IERC20.mint(crystal_address, to, crystal)
    IERC20.mint(deuterium_address, to, deuterium)
    return ()
end

func _pay_resources_erc20{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        address : felt, metal_amount : felt, crystal_amount : felt, deuterium_amount : felt):
    let (metal_address) = erc20_metal_address.read()
    let (crystal_address) = erc20_crystal_address.read()
    let (deuterium_address) = erc20_deuterium_address.read()
    let metal = Uint256(metal_amount * 10, 0)
    let crystal = Uint256(crystal_amount * 10, 0)
    let deuterium = Uint256(deuterium_amount * 10, 0)
    IERC20.burn(metal_address, address, metal)
    IERC20.burn(crystal_address, address, crystal)
    IERC20.burn(deuterium_address, address, deuterium)
    return ()
end

func _get_net_energy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        metal_level : felt, crystal_level : felt, deuterium_level : felt,
        solar_plant_level : felt) -> (net_energy : felt):
    alloc_locals
    let (metal_consumption) = _consumption(metal_level)
    let (crystal_consumption) = _consumption(crystal_level)
    let (deuterium_consumption) = _consumption_deuterium(deuterium_level)
    let total_energy_required = metal_consumption + crystal_consumption + deuterium_consumption
    let (energy_available) = _solar_production_formula(solar_plant_level)
    let (not_negative_energy) = is_le(total_energy_required, energy_available)
    if not_negative_energy == FALSE:
        return (0)
    else:
        let res = energy_available - total_energy_required
    end
    return (res)
end
