################################################################################                                                     
## 
##   CAN with Flexible Data-Rate IP Core 
##   
##   Copyright (C) 2018 Ondrej Ille <ondrej.ille@gmail.com>
##
##   Address map generator to VHDL package with constants.  
## 
##	Revision history:
##		25.01.2018	First implementation
##
################################################################################

from abc import ABCMeta, abstractmethod
from pyXact_generator.ip_xact.addr_generator import IpXactAddrGenerator

from pyXact_generator.languages.gen_vhdl import VhdlGenerator
from pyXact_generator.languages.declaration import LanDeclaration

class VhdlAddrGenerator(IpXactAddrGenerator):

	vhdlGen = None

	def __init__(self, pyXactComp, addrMap, fieldMap, busWidth):
		super().__init__(pyXactComp, addrMap, fieldMap, busWidth)
		self.vhdlGen = VhdlGenerator()
	
	
	def commit_to_file(self):
		for line in self.vhdlGen.out :
			self.of.write(line)
	
	
	def write_reg_enums(self, field):
		if (field.enumeratedValues == []):
			return False
		
		self.vhdlGen.wr_nl()
		self.vhdlGen.write_comment('"{}" field enumerated values'.format(
								field.name), 2, small=True)
		for es in field.enumeratedValues:
			for e in sorted(es.enumeratedValue, key=lambda x: x.value):
				decl = LanDeclaration(e.name, e.value, "std_logic",
							field.bitWidth, "constant", 50)
				self.vhdlGen.write_decl(decl)
				
	def write_res_vals(self, field):
		if (field.resets == None):
			return False
		
		if (field.resets.reset == None):
			return False
			
		decl = LanDeclaration(field.name+"_RSTVAL", field.resets.reset.value,
								"std_logic", field.bitWidth, "constant", 50)
		self.vhdlGen.write_decl(decl)


	def write_reg_field(self, field, reg):
		bitIndexL = field.bitOffset
		bitIndexH = field.bitOffset + field.bitWidth-1
	
		bitIndexL = bitIndexL + ((reg.addressOffset*8) % self.busWidth)
		bitIndexH = bitIndexH + ((reg.addressOffset*8) % self.busWidth)
		
		if (bitIndexH == bitIndexL):
			iter = [["_IND", bitIndexL]]
		else:
			iter = [["_L", bitIndexL], ["_H", bitIndexH]]
			
		for item in iter:
			decl = LanDeclaration(field.name+item[0], item[1], "natural",
									field.bitWidth, "constant", 50)
			self.vhdlGen.write_decl(decl)
			
	
	def __write_reg(self, reg, writeFields, writeEnums, writeReset):
		
		# Write the register title
		capt = '{} register'.format(reg.name.upper())
		self.vhdlGen.write_comment(reg.description, 2, caption=capt)
								
		#Write the individual elements
		if (writeFields == True):
			for field in sorted(reg.field, key=lambda a: a.bitOffset):
				self.write_reg_field(field, reg)
		
		#Write the enums (iterate separately not to mix up fields and enums)
		if (writeEnums == True):
			for field in reg.field:
				self.write_reg_enums(field)
			self.vhdlGen.wr_nl()
		
		#Write reset values for each field
		if (writeReset == True):
			self.vhdlGen.write_comment("{} register reset values".format(
									reg.name.upper()), 2, small=True)
			for field in reg.field:
				self.write_res_vals(field)
		self.vhdlGen.wr_nl()

	
	def write_regs(self, regs):
		for reg in sorted(regs, key=lambda a: a.addressOffset):
			self.__write_reg(reg, True, True, True)


	def write_addrbl_head(self, addressBlock):
		# Write capital comment with name of the address Block
		self.vhdlGen.write_comm_line()
		self.vhdlGen.write_comment("Address block: {}".format(addressBlock.name), 2)
		self.vhdlGen.write_comm_line()
		
		# Write the VHDL constant for Address block offset defined as:
		#	block.baseAddress/block.range
		bitWidth = 4 # TODO: So far not bound to IP-XACT
		decl = LanDeclaration(addressBlock.name+"_BLOCK", 
					addressBlock.baseAddress/addressBlock.range,
					"std_logic", bitWidth, "constant", 80)	
		self.vhdlGen.write_decl(decl)
		self.vhdlGen.wr_nl()
		

	def write_addrbl_regs(self, addressBlock):
		for reg in sorted(addressBlock.register, key=lambda a: a.addressOffset):
			decl = LanDeclaration(reg.name+"_ADR",
						reg.addressOffset+addressBlock.baseAddress, "std_logic",
						12, "constant", 80)
			self.vhdlGen.write_decl(decl)


	def write_mem_map_addr(self):
		#Each Address block reflects to VHDL memory region
		for block in self.addrMap.addressBlock:
			self.write_addrbl_head(block)
			self.write_addrbl_regs(block)
			self.vhdlGen.wr_nl()

	def write_mem_map_fields(self):
		for block in self.fieldMap.addressBlock:
			self.write_regs(block.register)


	def write_mem_map_both(self):
		self.write_mem_map_fields()
		self.write_mem_map_addr()
		
		
	def create_addrMap_package(self, name):
		
		self.vhdlGen.wr_nl()
		self.vhdlGen.write_comm_line(gap=0)
		if (self.addrMap != None):
			print ("Writing addresses of '%s' register map" % self.addrMap.name)
			self.vhdlGen.write_comment("Addresses map for: {}".format(
											self.addrMap.name), 0, small=True)
		if (self.fieldMap != None):
			print ("Writing bit fields of '%s' register map" % self.fieldMap.name)
			self.vhdlGen.write_comment("Field map for: {}".format(self.fieldMap.name),
											0, small=True)
		self.vhdlGen.write_comment("This file is autogenerated, DO NOT EDIT!",
										0, small=True)
								
		self.vhdlGen.write_comm_line(gap=0)
		self.vhdlGen.wr_nl()
		
		self.vhdlGen.create_includes(["std_logic_1164.all"])
		self.vhdlGen.wr_nl()
		self.vhdlGen.create_package(name, start=True)
		self.vhdlGen.wr_nl()
		if (self.addrMap):
			self.write_mem_map_addr()
		if (self.fieldMap):
			self.write_mem_map_fields()
		self.vhdlGen.create_package(name, start=False)
				

	def write_reg(self, reg, writeFields, writeRstVal, writeEnums): 
		self.__write_reg(self, reg, writeFields, writeEnums, writeRstVal)

	
	
	