/*
* Copyright (C) 2016-2019, L-Acoustics and its contributors

* This file is part of LA_avdecc.

* LA_avdecc is free software: you can redistribute it and/or modify
* it under the terms of the GNU Lesser General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.

* LA_avdecc is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU Lesser General Public License for more details.

* You should have received a copy of the GNU Lesser General Public License
* along with LA_avdecc.  If not, see <http://www.gnu.org/licenses/>.
*/

/**
* @file protocolInterface_macNative.mm
* @author Christophe Calmejane
*/

#include "la/avdecc/internals/protocolAemAecpdu.hpp"
#include "la/avdecc/internals/protocolAaAecpdu.hpp"
#include "la/avdecc/internals/protocolVuAecpdu.hpp"

#include "stateMachine/stateMachineManager.hpp"
#include "protocolInterface_macNative.hpp"
#include "logHelper.hpp"

#include <stdexcept>
#include <functional>
#include <memory>
#include <string>
#include <optional>
#include <sstream>
#include <thread>
#include <unordered_map>
#include <unordered_set>

#import <AudioVideoBridging/AudioVideoBridging.h>

#pragma mark Forward declaration of ProtocolInterfaceMacNativeImpl
namespace la
{
namespace avdecc
{
namespace protocol
{
class ProtocolInterfaceMacNativeImpl;
} // namespace protocol
} // namespace avdecc
} // namespace la

#pragma mark - FromNative Declaration

@interface FromNative : NSObject
+ (la::avdecc::entity::Entity)makeEntity:(AVB17221Entity*)entity;
+ (la::avdecc::protocol::Aecpdu::UniquePointer)makeAecpdu:(AVB17221AECPMessage*)message toDestAddress:(la::avdecc::networkInterface::MacAddress const&)destAddress;
+ (la::avdecc::protocol::Acmpdu::UniquePointer)makeAcmpdu:(AVB17221ACMPMessage*)message;
+ (la::avdecc::networkInterface::MacAddress)makeMacAddress:(AVBMACAddress*)macAddress;
+ (la::avdecc::protocol::ProtocolInterface::Error)getProtocolError:(NSError*)error;
@end

#pragma mark - FromNative Implementation

@implementation FromNative
+ (la::avdecc::networkInterface::MacAddress)getFirstMacAddress:(NSArray*)array {
	la::avdecc::networkInterface::MacAddress mac;

	if (array.count > 0)
	{
		auto data = [(AVBMACAddress*)[array objectAtIndex:0] dataRepresentation];
		if (data.length == mac.size())
		{
			auto const* dataPtr = static_cast<decltype(mac)::value_type const*>(data.bytes);
			for (auto& v : mac)
			{
				v = *dataPtr;
				++dataPtr;
			}
		}
	}
	return mac;
}

+ (la::avdecc::entity::Entity)makeEntity:(AVB17221Entity*)entity {
	auto const entityCaps = static_cast<la::avdecc::entity::EntityCapabilities>(entity.entityCapabilities);
	auto controlIndex{ std::optional<la::avdecc::entity::model::ControlIndex>{} };
	auto associationID{ std::optional<la::avdecc::UniqueIdentifier>{} };
	auto avbInterfaceIndex{ la::avdecc::entity::Entity::GlobalAvbInterfaceIndex };
	auto gptpGrandmasterID{ std::optional<la::avdecc::UniqueIdentifier>{} };
	auto gptpDomainNumber{ std::optional<std::uint8_t>{} };

	if (la::avdecc::utils::hasFlag(entityCaps, la::avdecc::entity::EntityCapabilities::AemIdentifyControlIndexValid))
	{
		controlIndex = entity.identifyControlIndex;
	}
	if (la::avdecc::utils::hasFlag(entityCaps, la::avdecc::entity::EntityCapabilities::AssociationIDValid))
	{
		associationID = entity.associationID;
	}
	if (la::avdecc::utils::hasFlag(entityCaps, la::avdecc::entity::EntityCapabilities::AemInterfaceIndexValid))
	{
		avbInterfaceIndex = entity.interfaceIndex;
	}
	if (la::avdecc::utils::hasFlag(entityCaps, la::avdecc::entity::EntityCapabilities::GptpSupported))
	{
		gptpGrandmasterID = entity.gPTPGrandmasterID;
		gptpDomainNumber = entity.gPTPDomainNumber;
	}

	auto const commonInfo{ la::avdecc::entity::Entity::CommonInformation{ entity.entityID, entity.entityModelID, entityCaps, entity.talkerStreamSources, static_cast<la::avdecc::entity::TalkerCapabilities>(entity.talkerCapabilities), entity.listenerStreamSinks, static_cast<la::avdecc::entity::ListenerCapabilities>(entity.listenerCapabilities), static_cast<la::avdecc::entity::ControllerCapabilities>(entity.controllerCapabilities), controlIndex, associationID } };
	auto const interfaceInfo{ la::avdecc::entity::Entity::InterfaceInformation{ [FromNative getFirstMacAddress:entity.macAddresses], static_cast<std::uint8_t>(entity.timeToLive / 2u), entity.availableIndex, gptpGrandmasterID, gptpDomainNumber } };

	return la::avdecc::entity::Entity{ commonInfo, { { avbInterfaceIndex, interfaceInfo } } };
}

+ (la::avdecc::protocol::AemAecpdu::UniquePointer)makeAemAecpdu:(AVB17221AECPAEMMessage*)message toDestAddress:(la::avdecc::networkInterface::MacAddress const&)destAddress isResponse:(bool)isResponse {
	auto aemAecpdu = la::avdecc::protocol::AemAecpdu::create(isResponse);
	auto& aem = static_cast<la::avdecc::protocol::AemAecpdu&>(*aemAecpdu);

	// Set Ether2 fields
	aem.setSrcAddress([FromNative makeMacAddress:message.sourceMAC]);
	aem.setDestAddress(destAddress);

	// Set AECP fields
	aem.setStatus(la::avdecc::protocol::AecpStatus{ message.status });
	aem.setTargetEntityID(message.targetEntityID);
	aem.setControllerEntityID(message.controllerEntityID);
	aem.setSequenceID(message.sequenceID);

	// Set AEM fields
	aem.setUnsolicited(message.isUnsolicited);
	aem.setCommandType(la::avdecc::protocol::AemCommandType{ message.commandType });
	if (message.commandSpecificData.length != 0)
		aem.setCommandSpecificData(message.commandSpecificData.bytes, message.commandSpecificData.length);

	return aemAecpdu;
}

+ (la::avdecc::protocol::AaAecpdu::UniquePointer)makeAaAecpdu:(AVB17221AECPAddressAccessMessage*)message toDestAddress:(la::avdecc::networkInterface::MacAddress const&)destAddress isResponse:(bool)isResponse {
	auto aaAecpdu = la::avdecc::protocol::AaAecpdu::create(isResponse);
	auto& aa = static_cast<la::avdecc::protocol::AaAecpdu&>(*aaAecpdu);

	// Set Ether2 fields
	aa.setSrcAddress([FromNative makeMacAddress:message.sourceMAC]);
	aa.setDestAddress(destAddress);

	// Set AECP fields
	aa.setStatus(la::avdecc::protocol::AecpStatus(message.status));
	aa.setTargetEntityID(message.targetEntityID);
	aa.setControllerEntityID(message.controllerEntityID);
	aa.setSequenceID(message.sequenceID);

	// Set Address Access fields
	for (AVB17221AECPAddressAccessTLV* tlv in message.tlvs)
	{
		aa.addTlv(la::avdecc::entity::addressAccess::Tlv{ tlv.address, static_cast<la::avdecc::protocol::AaMode>(tlv.mode), tlv.memoryData.bytes, tlv.memoryData.length });
	}

	return aaAecpdu;
}

+ (la::avdecc::protocol::VuAecpdu::UniquePointer)makeVendorUniqueAecpdu:(AVB17221AECPVendorMessage*)message toDestAddress:(la::avdecc::networkInterface::MacAddress const&)destAddress isResponse:(bool)isResponse {
#pragma message("TODO")
	return la::avdecc::protocol::VuAecpdu::UniquePointer{ nullptr, nullptr };
}

+ (la::avdecc::protocol::Aecpdu::UniquePointer)makeAecpdu:(AVB17221AECPMessage*)message toDestAddress:(la::avdecc::networkInterface::MacAddress const&)destAddress {
	switch ([message messageType])
	{
		case AVB17221AECPMessageTypeAEMCommand:
			return [FromNative makeAemAecpdu:static_cast<AVB17221AECPAEMMessage*>(message) toDestAddress:destAddress isResponse:false];
		case AVB17221AECPMessageTypeAEMResponse:
			return [FromNative makeAemAecpdu:static_cast<AVB17221AECPAEMMessage*>(message) toDestAddress:destAddress isResponse:true];
		case AVB17221AECPMessageTypeAddressAccessCommand:
			return [FromNative makeAaAecpdu:static_cast<AVB17221AECPAddressAccessMessage*>(message) toDestAddress:destAddress isResponse:false];
		case AVB17221AECPMessageTypeAddressAccessResponse:
			return [FromNative makeAaAecpdu:static_cast<AVB17221AECPAddressAccessMessage*>(message) toDestAddress:destAddress isResponse:true];
		case AVB17221AECPMessageTypeVendorUniqueCommand:
			return [FromNative makeVendorUniqueAecpdu:static_cast<AVB17221AECPVendorMessage*>(message) toDestAddress:destAddress isResponse:false];
		case AVB17221AECPMessageTypeVendorUniqueResponse:
			return [FromNative makeVendorUniqueAecpdu:static_cast<AVB17221AECPVendorMessage*>(message) toDestAddress:destAddress isResponse:true];
		default:
			AVDECC_ASSERT(false, "Unhandled AECP message type");
			break;
	}
	return { nullptr, nullptr };
}

+ (la::avdecc::protocol::Acmpdu::UniquePointer)makeAcmpdu:(AVB17221ACMPMessage*)message {
	auto acmpdu = la::avdecc::protocol::Acmpdu::create();
	auto& acmp = static_cast<la::avdecc::protocol::Acmpdu&>(*acmpdu);

	// Set Ether2 fields
#pragma message("TBD: Find a way to retrieve these information")
	//aem.setSrcAddress();
	//aem.setDestAddress();

	// Set ACMP fields
	acmp.setMessageType(la::avdecc::protocol::AcmpMessageType(message.messageType));
	acmp.setStatus(la::avdecc::protocol::AcmpStatus(message.status));
	acmp.setStreamID(message.streamID);
	acmp.setControllerEntityID(message.controllerEntityID);
	acmp.setTalkerEntityID(message.talkerEntityID);
	acmp.setListenerEntityID(message.listenerEntityID);
	acmp.setTalkerUniqueID(message.talkerUniqueID);
	acmp.setListenerUniqueID(message.listenerUniqueID);
	acmp.setStreamDestAddress([FromNative makeMacAddress:message.destinationMAC]);
	acmp.setConnectionCount(message.connectionCount);
	acmp.setSequenceID(message.sequenceID);
	acmp.setFlags(la::avdecc::entity::ConnectionFlags(message.flags));
	acmp.setStreamVlanID(message.vlanID);

	return acmpdu;
}

+ (la::avdecc::networkInterface::MacAddress)makeMacAddress:(AVBMACAddress*)macAddress {
	la::avdecc::networkInterface::MacAddress mac;
	auto const* data = [macAddress dataRepresentation];
	auto const bufferSize = mac.size() * sizeof(la::avdecc::networkInterface::MacAddress::value_type);

	if (data.length == bufferSize)
		memcpy(mac.data(), data.bytes, bufferSize);

	return mac;
}

+ (la::avdecc::protocol::ProtocolInterface::Error)getProtocolError:(NSError*)error {
	if ([[error domain] isEqualToString:AVBErrorDomain])
	{
		auto const code = IOReturn(error.code);
		switch (code)
		{
			case kIOReturnTimeout:
				return la::avdecc::protocol::ProtocolInterface::Error::Timeout;
			case kIOReturnExclusiveAccess:
				return la::avdecc::protocol::ProtocolInterface::Error::DuplicateLocalEntityID;
			case kIOReturnNotFound:
				return la::avdecc::protocol::ProtocolInterface::Error::UnknownLocalEntity;
			case kIOReturnOffline:
				return la::avdecc::protocol::ProtocolInterface::Error::TransportError;
			case kIOReturnBadArgument:
				return la::avdecc::protocol::ProtocolInterface::Error::InternalError;
			default:
				NSLog(@"Not handled IOReturn error code: %x\n", code);
				AVDECC_ASSERT(false, "Not handled error code");
				return la::avdecc::protocol::ProtocolInterface::Error::TransportError;
		}
	}

	return la::avdecc::protocol::ProtocolInterface::Error::InternalError;
}

@end

#pragma mark - ToNative Declaration

@interface ToNative : NSObject
+ (AVB17221Entity*)makeAVB17221Entity:(la::avdecc::entity::Entity const&)entity interfaceIndex:(la::avdecc::entity::model::AvbInterfaceIndex)interfaceIndex;
+ (AVB17221AECPMessage*)makeAecpMessage:(la::avdecc::protocol::Aecpdu const&)message;
+ (AVBMACAddress*)makeAVBMacAddress:(la::avdecc::networkInterface::MacAddress const&)macAddress;
@end

#pragma mark - ToNative Implementation

@implementation ToNative
+ (AVB17221Entity*)makeAVB17221Entity:(la::avdecc::entity::Entity const&)entity interfaceIndex:(la::avdecc::entity::model::AvbInterfaceIndex)interfaceIndex {
	auto& interfaceInfo = entity.getInterfaceInformation(interfaceIndex);
	auto entityCaps{ entity.getEntityCapabilities() };
	auto identifyControlIndex{ la::avdecc::entity::model::ControlIndex{ 0u } };
	auto avbInterfaceIndex{ la::avdecc::entity::model::AvbInterfaceIndex{ 0u } };
	auto associationID{ la::avdecc::UniqueIdentifier::getNullUniqueIdentifier() };
	auto gptpGrandmasterID{ la::avdecc::UniqueIdentifier::getNullUniqueIdentifier() };
	auto gptpDomainNumber{ std::uint8_t{ 0u } };

	if (entity.getIdentifyControlIndex())
	{
		la::avdecc::utils::addFlag(entityCaps, la::avdecc::entity::EntityCapabilities::AemIdentifyControlIndexValid);
		identifyControlIndex = *entity.getIdentifyControlIndex();
	}
	else
	{
		// We don't have a valid IdentifyControlIndex, don't set the flag
		la::avdecc::utils::clearFlag(entityCaps, la::avdecc::entity::EntityCapabilities::AemIdentifyControlIndexValid);
	}

	if (interfaceIndex != la::avdecc::entity::Entity::GlobalAvbInterfaceIndex)
	{
		la::avdecc::utils::addFlag(entityCaps, la::avdecc::entity::EntityCapabilities::AemInterfaceIndexValid);
		avbInterfaceIndex = interfaceIndex;
	}
	else
	{
		// We don't have a valid AvbInterfaceIndex, don't set the flag
		la::avdecc::utils::clearFlag(entityCaps, la::avdecc::entity::EntityCapabilities::AemInterfaceIndexValid);
	}

	if (entity.getAssociationID())
	{
		la::avdecc::utils::addFlag(entityCaps, la::avdecc::entity::EntityCapabilities::AssociationIDValid);
		associationID = *entity.getAssociationID();
	}
	else
	{
		// We don't have a valid AssociationID, don't set the flag
		la::avdecc::utils::clearFlag(entityCaps, la::avdecc::entity::EntityCapabilities::AssociationIDValid);
	}

	if (interfaceInfo.gptpGrandmasterID)
	{
		la::avdecc::utils::addFlag(entityCaps, la::avdecc::entity::EntityCapabilities::GptpSupported);
		gptpGrandmasterID = *interfaceInfo.gptpGrandmasterID;
		if (AVDECC_ASSERT_WITH_RET(interfaceInfo.gptpDomainNumber, "gptpDomainNumber should be set when gptpGrandmasterID is set"))
		{
			gptpDomainNumber = *interfaceInfo.gptpDomainNumber;
		}
	}
	else
	{
		// We don't have a valid gptpGrandmasterID value, don't set the flag
		la::avdecc::utils::clearFlag(entityCaps, la::avdecc::entity::EntityCapabilities::GptpSupported);
	}

	auto e = [[AVB17221Entity alloc] init];

	e.entityID = entity.getEntityID();
	e.entityModelID = entity.getEntityModelID();
	e.entityCapabilities = static_cast<AVB17221ADPEntityCapabilities>(entityCaps);
	e.talkerStreamSources = entity.getTalkerStreamSources();
	e.talkerCapabilities = static_cast<AVB17221ADPTalkerCapabilities>(entity.getTalkerCapabilities());
	e.listenerStreamSinks = entity.getListenerStreamSinks();
	e.listenerCapabilities = static_cast<AVB17221ADPListenerCapabilities>(entity.getListenerCapabilities());
	e.controllerCapabilities = static_cast<AVB17221ADPControllerCapabilities>(entity.getControllerCapabilities());
	e.identifyControlIndex = identifyControlIndex;
	e.interfaceIndex = avbInterfaceIndex;
	e.associationID = associationID;
	e.gPTPGrandmasterID = gptpGrandmasterID;
	e.gPTPDomainNumber = gptpDomainNumber;
	e.timeToLive = interfaceInfo.validTime * 2u;

	e.availableIndex = 0; // AvailableIndex is automatically handled by macOS APIs
	return e;
}

+ (AVB17221AECPAEMMessage*)makeAemMessage:(la::avdecc::protocol::AemAecpdu const&)aecpdu isResponse:(bool)isResponse {
	auto* message = static_cast<AVB17221AECPAEMMessage*>(nullptr);

	if (isResponse)
		message = [AVB17221AECPAEMMessage responseMessage];
	else
		message = [AVB17221AECPAEMMessage commandMessage];

	// Set Aem specific fields
	message.unsolicited = FALSE;
	message.controllerRequest = FALSE;
	message.commandType = static_cast<AVB17221AEMCommandType>(aecpdu.getCommandType().getValue());
	auto const payloadInfo = aecpdu.getPayload();
	auto const* const payload = payloadInfo.first;
	if (payload != nullptr)
	{
		message.commandSpecificData = [NSData dataWithBytes:payload length:payloadInfo.second];
	}

	// Set common fields
	message.status = AVB17221AECPStatusSuccess;
	message.targetEntityID = aecpdu.getTargetEntityID();
	message.controllerEntityID = aecpdu.getControllerEntityID();
	message.sequenceID = aecpdu.getSequenceID();

	return message;
}

+ (AVB17221AECPAddressAccessMessage*)makeAaMessage:(la::avdecc::protocol::AaAecpdu const&)aecpdu isResponse:(bool)isResponse {
	auto* message = static_cast<AVB17221AECPAddressAccessMessage*>(nullptr);

	if (isResponse)
		message = [AVB17221AECPAddressAccessMessage responseMessage];
	else
		message = [AVB17221AECPAddressAccessMessage commandMessage];

	// Set AA specific fields
	auto* tlvs = [[NSMutableArray alloc] init];
	for (auto const& tlv : aecpdu.getTlvData())
	{
		auto* t = [[AVB17221AECPAddressAccessTLV alloc] init];
		t.mode = static_cast<AVB17221AECPAddressAccessTLVMode>(tlv.getMode().getValue());
		t.address = tlv.getAddress();
		t.memoryData = [NSData dataWithBytes:tlv.getMemoryData().data() length:tlv.getMemoryData().size()];
		[tlvs addObject:t];
	}
	message.tlvs = tlvs;

	// Set common fields
	message.status = AVB17221AECPStatusSuccess;
	message.targetEntityID = aecpdu.getTargetEntityID();
	message.controllerEntityID = aecpdu.getControllerEntityID();
	message.sequenceID = aecpdu.getSequenceID();

	return message;
}

+ (AVB17221AECPVendorMessage*)makeVendorUniqueMessage:(la::avdecc::protocol::VuAecpdu const&)aecpdu isResponse:(bool)isResponse {
	auto const message = [[AVB17221AECPVendorMessage alloc] init];
#if !__has_feature(objc_arc)
	[message autorelease];
#endif

	// Set Vendor Unique specific fields
	{
		message.protocolID = static_cast<la::avdecc::protocol::VuAecpdu::ProtocolIdentifier::IntegralType>(aecpdu.getProtocolIdentifier());
	}
	{
		// Use VuAecpdu serialization to construct the vendor specific payload
		la::avdecc::protocol::SerializationBuffer buffer;
		la::avdecc::protocol::serialize<la::avdecc::protocol::VuAecpdu>(aecpdu, buffer);

		// Copy the payload to commandSpecificData, minus the header
		auto constexpr HeaderLength = la::avdecc::protocol::Aecpdu::HeaderLength + la::avdecc::protocol::VuAecpdu::HeaderLength;
		auto const* const payloadData = buffer.data();
		auto const payloadLength = buffer.size();
		if (payloadLength > HeaderLength)
		{
			message.protocolSpecificData = [NSData dataWithBytes:(payloadData + HeaderLength) length:payloadLength - HeaderLength];
		}
	}

	// Set common fields
	message.messageType = isResponse ? AVB17221AECPMessageTypeVendorUniqueResponse : AVB17221AECPMessageTypeVendorUniqueCommand;
	message.status = AVB17221AECPStatusSuccess;
	message.targetEntityID = aecpdu.getTargetEntityID();
	message.controllerEntityID = aecpdu.getControllerEntityID();
	message.sequenceID = aecpdu.getSequenceID();

	return message;
}

+ (AVB17221AECPMessage*)makeAecpMessage:(la::avdecc::protocol::Aecpdu const&)message {
	switch (static_cast<AVB17221AECPMessageType>(message.getMessageType().getValue()))
	{
		case AVB17221AECPMessageTypeAEMCommand:
			return [ToNative makeAemMessage:static_cast<la::avdecc::protocol::AemAecpdu const&>(message) isResponse:false];
		case AVB17221AECPMessageTypeAEMResponse:
			return [ToNative makeAemMessage:static_cast<la::avdecc::protocol::AemAecpdu const&>(message) isResponse:true];
		case AVB17221AECPMessageTypeAddressAccessCommand:
			return [ToNative makeAaMessage:static_cast<la::avdecc::protocol::AaAecpdu const&>(message) isResponse:false];
		case AVB17221AECPMessageTypeAddressAccessResponse:
			return [ToNative makeAaMessage:static_cast<la::avdecc::protocol::AaAecpdu const&>(message) isResponse:true];
		case AVB17221AECPMessageTypeVendorUniqueCommand:
			return [ToNative makeVendorUniqueMessage:static_cast<la::avdecc::protocol::VuAecpdu const&>(message) isResponse:false];
		case AVB17221AECPMessageTypeVendorUniqueResponse:
			return [ToNative makeVendorUniqueMessage:static_cast<la::avdecc::protocol::VuAecpdu const&>(message) isResponse:true];
		default:
			AVDECC_ASSERT(false, "Unhandled AECP message type");
			break;
	}
	return NULL;
}

+ (AVBMACAddress*)makeAVBMacAddress:(la::avdecc::networkInterface::MacAddress const&)macAddress {
	auto* mac = [[AVBMACAddress alloc] initWithBytes:macAddress.data()];
#if !__has_feature(objc_arc)
	[mac autorelease];
#endif
	return mac;
}

@end

#pragma mark - BridgeInterface Declaration
struct EntityQueues
{
	dispatch_queue_t aecpQueue;
	dispatch_semaphore_t aecpLimiter;
};

struct LockInformation
{
	std::recursive_mutex _lock{};
	std::uint32_t _lockedCount{ 0u };
	std::thread::id _lockingThreadID{};

	void lock() noexcept
	{
		_lock.lock();
		if (_lockedCount == 0)
		{
			_lockingThreadID = std::this_thread::get_id();
		}
		++_lockedCount;
	}

	void unlock() noexcept
	{
		--_lockedCount;
		if (_lockedCount == 0)
		{
			_lockingThreadID = {};
		}
		_lock.unlock();
	}

	bool isSelfLocked() const noexcept
	{
		return _lockingThreadID == std::this_thread::get_id();
	}
};

@interface BridgeInterface : NSObject <AVB17221EntityDiscoveryDelegate, AVB17221AECPClient, AVB17221ACMPClient>
// Private variables
{
	BOOL _primedDiscovery;
	la::avdecc::protocol::ProtocolInterfaceMacNativeImpl* _protocolInterface;

	LockInformation _lock; /** Lock to protect the ProtocolInterface */
	std::unordered_map<la::avdecc::UniqueIdentifier, std::uint32_t, la::avdecc::UniqueIdentifier::hash> _lastAvailableIndex; /** Last received AvailableIndex for each entity */
	std::unordered_map<la::avdecc::UniqueIdentifier, la::avdecc::entity::LocalEntity&, la::avdecc::UniqueIdentifier::hash> _localProcessEntities; /** Local entities declared by the running process */
	std::unordered_set<la::avdecc::UniqueIdentifier, la::avdecc::UniqueIdentifier::hash> _registeredAcmpHandlers; /** List of ACMP handlers that have been registered (that must be removed upon destruction, since there is no removeAllHandlers method) */

	std::mutex _lockQueues; /** Lock to protect _entityQueues */
	std::unordered_map<la::avdecc::UniqueIdentifier, EntityQueues, la::avdecc::UniqueIdentifier::hash> _entityQueues;

	std::mutex _lockPending; /** Lock to protect _pendingCommands and _pendingCondVar */
	std::uint32_t _pendingCommands; /** Count of pending (inflight) commands, since there is no way to cancel a command upon destruction (and result block might be called while we already destroyed our objects) */
	std::condition_variable _pendingCondVar;
}

+ (BOOL)isSupported;
/** std::string to NSString conversion */
+ (NSString*)getNSString:(std::string const&)cString;
/** NSString to std::string conversion */
+ (std::string)getStdString:(NSString*)nsString;
+ (NSString*)getEntityCapabilities:(AVB17221Entity*)entity;

- (std::optional<la::avdecc::entity::model::AvbInterfaceIndex>)getMatchingInterfaceIndex:(la::avdecc::entity::LocalEntity const&)entity;

/** Initializer */
- (id)initWithInterfaceName:(NSString*)interfaceName andProtocolInterface:(la::avdecc::protocol::ProtocolInterfaceMacNativeImpl*)protocolInterface;
/** Deinit method to shutdown every pending operations */
- (void)deinit;
/** Destructor */
- (void)dealloc;

// la::avdecc::protocol::ProtocolInterface bridge methods
- (la::avdecc::UniqueIdentifier)getDynamicEID;
- (void)releaseDynamicEID:(la::avdecc::UniqueIdentifier)entityID;
// Registration of a local process entity (an entity declared inside this process, not all local computer entities)
- (la::avdecc::protocol::ProtocolInterface::Error)registerLocalEntity:(la::avdecc::entity::LocalEntity&)entity;
// Remove handlers for a local process entity
- (void)removeLocalProcessEntityHandlers:(la::avdecc::entity::LocalEntity const&)entity;
// Unregistration of a local process entity
- (la::avdecc::protocol::ProtocolInterface::Error)unregisterLocalEntity:(la::avdecc::entity::LocalEntity const&)entity;
- (la::avdecc::protocol::ProtocolInterface::Error)setEntityNeedsAdvertise:(la::avdecc::entity::LocalEntity const&)entity flags:(la::avdecc::entity::LocalEntity::AdvertiseFlags)flags;
- (la::avdecc::protocol::ProtocolInterface::Error)enableEntityAdvertising:(la::avdecc::entity::LocalEntity const&)entity;
- (la::avdecc::protocol::ProtocolInterface::Error)disableEntityAdvertising:(la::avdecc::entity::LocalEntity const&)entity;
- (BOOL)discoverRemoteEntities;
- (BOOL)discoverRemoteEntity:(la::avdecc::UniqueIdentifier)entityID;
- (la::avdecc::protocol::ProtocolInterface::Error)sendAecpCommand:(la::avdecc::protocol::Aecpdu::UniquePointer&&)aecpdu handler:(la::avdecc::protocol::ProtocolInterface::AecpCommandResultHandler const&)onResult;
- (la::avdecc::protocol::ProtocolInterface::Error)sendAecpResponse:(la::avdecc::protocol::Aecpdu::UniquePointer&&)aecpdu;
- (la::avdecc::protocol::ProtocolInterface::Error)sendAcmpCommand:(la::avdecc::protocol::Acmpdu::UniquePointer&&)acmpdu handler:(la::avdecc::protocol::ProtocolInterface::AcmpCommandResultHandler const&)onResult;
- (void)lock;
- (void)unlock;
- (bool)isSelfLocked;

// Variables
@property (retain) AVBInterface* interface;

@end

#pragma mark - ProtocolInterfaceMacNativeImpl Implementation
namespace la
{
namespace avdecc
{
namespace protocol
{
class ProtocolInterfaceMacNativeImpl final : public ProtocolInterfaceMacNative, private stateMachine::ProtocolInterfaceDelegate
{
public:
	// Publicly expose notifyObservers methods so the objC code can use it directly
	using ProtocolInterfaceMacNative::notifyObservers;
	using ProtocolInterfaceMacNative::notifyObserversMethod;

	/** Constructor */
	ProtocolInterfaceMacNativeImpl(std::string const& networkInterfaceName)
		: ProtocolInterfaceMacNative(networkInterfaceName)
	{
		// Should not be there if the interface is not supported
		AVDECC_ASSERT(isSupported(), "Should not be there if the interface is not supported");

		auto* intName = [BridgeInterface getNSString:networkInterfaceName];

#if 0 // We don't need to check for AVB capability/enable on the interface, AVDECC do not require an AVB compatible interface \
	// Check the interface is AVB enabled
					if(![AVBInterface isAVBEnabledOnInterfaceNamed:intName])
					{
						throw std::invalid_argument("Interface is not AVB enabled");
					}
					// Check the interface is AVB capable
					if(![AVBInterface isAVBCapableInterfaceNamed:intName])
					{
						throw std::invalid_argument("Interface is not AVB capable");
					}
#endif // 0

		// We can now create an AVBInterface from this network interface
		_bridge = [[BridgeInterface alloc] initWithInterfaceName:intName andProtocolInterface:this];

		// Start the state machines
		_stateMachineManager.startStateMachines();
	}

	/** Destructor */
	virtual ~ProtocolInterfaceMacNativeImpl() noexcept
	{
		shutdown();
	}

	/** Destroy method for COM-like interface */
	virtual void destroy() noexcept override
	{
		delete this;
	}

	// Deleted compiler auto-generated methods
	ProtocolInterfaceMacNativeImpl(ProtocolInterfaceMacNativeImpl&&) = delete;
	ProtocolInterfaceMacNativeImpl(ProtocolInterfaceMacNativeImpl const&) = delete;
	ProtocolInterfaceMacNativeImpl& operator=(ProtocolInterfaceMacNativeImpl const&) = delete;
	ProtocolInterfaceMacNativeImpl& operator=(ProtocolInterfaceMacNativeImpl&&) = delete;

private:
#pragma mark la::avdecc::protocol::ProtocolInterface overrides
	virtual void shutdown() noexcept override
	{
		// Stop the state machines
		_stateMachineManager.stopStateMachines();

		// Destroy the bridge
		if (_bridge != nullptr)
		{
			[_bridge deinit];
#if !__has_feature(objc_arc)
			[_bridge release];
#endif
			_bridge = nullptr;
		}
	}

	virtual UniqueIdentifier getDynamicEID() const noexcept override
	{
		return [_bridge getDynamicEID];
	}

	virtual void releaseDynamicEID(UniqueIdentifier const entityID) const noexcept override
	{
		[_bridge releaseDynamicEID:entityID];
	}

	virtual Error registerLocalEntity(entity::LocalEntity& entity) noexcept override
	{
		return [_bridge registerLocalEntity:entity];
	}

	virtual Error unregisterLocalEntity(entity::LocalEntity& entity) noexcept override
	{
		return [_bridge unregisterLocalEntity:entity];
	}

	virtual Error setEntityNeedsAdvertise(entity::LocalEntity const& entity, entity::LocalEntity::AdvertiseFlags const flags) noexcept override
	{
		return [_bridge setEntityNeedsAdvertise:entity flags:flags];
	}

	virtual Error enableEntityAdvertising(entity::LocalEntity& entity) noexcept override
	{
		return [_bridge enableEntityAdvertising:entity];
	}

	virtual Error disableEntityAdvertising(entity::LocalEntity const& entity) noexcept override
	{
		return [_bridge disableEntityAdvertising:entity];
	}

	virtual Error discoverRemoteEntities() const noexcept override
	{
		if ([_bridge discoverRemoteEntities])
			return ProtocolInterface::Error::NoError;
		return ProtocolInterface::Error::TransportError;
	}

	virtual Error discoverRemoteEntity(UniqueIdentifier const entityID) const noexcept override
	{
		if ([_bridge discoverRemoteEntity:entityID])
			return ProtocolInterface::Error::NoError;
		return ProtocolInterface::Error::TransportError;
	}

	virtual bool isDirectMessageSupported() const noexcept override
	{
		return false;
	}

	virtual Error sendAdpMessage(Adpdu const& adpdu) const noexcept override
	{
		return Error::MessageNotSupported;
	}

	virtual Error sendAecpMessage(Aecpdu const& aecpdu) const noexcept override
	{
		return Error::MessageNotSupported;
	}

	virtual Error sendAcmpMessage(Acmpdu const& acmpdu) const noexcept override
	{
		return Error::MessageNotSupported;
	}

	virtual Error sendAecpCommand(Aecpdu::UniquePointer&& aecpdu, AecpCommandResultHandler const& onResult) const noexcept override
	{
		return [_bridge sendAecpCommand:std::move(aecpdu) handler:onResult];
	}

	virtual Error sendAecpResponse(Aecpdu::UniquePointer&& aecpdu) const noexcept override
	{
		return [_bridge sendAecpResponse:std::move(aecpdu)];
	}

	virtual Error sendAcmpCommand(Acmpdu::UniquePointer&& acmpdu, AcmpCommandResultHandler const& onResult) const noexcept override
	{
		return [_bridge sendAcmpCommand:std::move(acmpdu) handler:onResult];
	}

	virtual Error sendAcmpResponse(Acmpdu::UniquePointer&& acmpdu) const noexcept override
	{
		AVDECC_ASSERT(false, "TBD: To be implemented");
		return ProtocolInterface::Error::InternalError;
		//return [_bridge sendAcmpResponse:std::move(acmpdu)];
	}

	virtual void lock() noexcept override
	{
		[_bridge lock];
	}

	virtual void unlock() noexcept override
	{
		[_bridge unlock];
	}

	virtual bool isSelfLocked() const noexcept override
	{
		return [_bridge isSelfLocked];
	}

#pragma mark stateMachine::ProtocolInterfaceDelegate overrides
	/* **** AECP notifications **** */
	virtual void onAecpCommand(la::avdecc::protocol::Aecpdu const& aecpdu) noexcept override
	{
		AVDECC_ASSERT(false, "Should never be called");
	}
	/* **** ACMP notifications **** */
	virtual void onAcmpCommand(la::avdecc::protocol::Acmpdu const& acmpdu) noexcept override
	{
		AVDECC_ASSERT(false, "Should never be called");
	}
	virtual void onAcmpResponse(la::avdecc::protocol::Acmpdu const& acmpdu) noexcept override
	{
		AVDECC_ASSERT(false, "Should never be called");
	}
	/* **** Sending methods **** */
	virtual ProtocolInterface::Error sendMessage(la::avdecc::protocol::Adpdu const& adpdu) const noexcept override
	{
		AVDECC_ASSERT(false, "Should never be called (if needed someday, just forward to _bridge");
		return ProtocolInterface::Error::InternalError;
	}
	virtual ProtocolInterface::Error sendMessage(la::avdecc::protocol::Aecpdu const& aecpdu) const noexcept override
	{
		AVDECC_ASSERT(false, "Should never be called (if needed someday, just forward to _bridge");
		return ProtocolInterface::Error::InternalError;
	}
	virtual ProtocolInterface::Error sendMessage(la::avdecc::protocol::Acmpdu const& acmpdu) const noexcept override
	{
		AVDECC_ASSERT(false, "Should never be called (if needed someday, just forward to _bridge");
		return ProtocolInterface::Error::InternalError;
	}

private:
#pragma mark Private variables
	BridgeInterface* _bridge{ nullptr };
	stateMachine::Manager _stateMachineManager{ this, this, nullptr, nullptr, nullptr }; // stateMachineManager only required to create the discovery thread (which will callback 'this')
};

ProtocolInterfaceMacNative::ProtocolInterfaceMacNative(std::string const& networkInterfaceName)
	: ProtocolInterface(networkInterfaceName)
{
}

bool ProtocolInterfaceMacNative::isSupported() noexcept
{
	return [BridgeInterface isSupported];
}

ProtocolInterfaceMacNative* ProtocolInterfaceMacNative::createRawProtocolInterfaceMacNative(std::string const& networkInterfaceName)
{
	return new ProtocolInterfaceMacNativeImpl(networkInterfaceName);
}

} // namespace protocol
} // namespace avdecc
} // namespace la

#pragma mark - BridgeInterface Implementation
@implementation BridgeInterface

- (EntityQueues const&)createQueuesForRemoteEntity:(la::avdecc::UniqueIdentifier)entityID {
	EntityQueues eq;
	eq.aecpQueue = dispatch_queue_create([[NSString stringWithFormat:@"%@.0x%016llx.aecp", [self className], entityID.getValue()] UTF8String], 0);
	eq.aecpLimiter = dispatch_semaphore_create(la::avdecc::protocol::Aecpdu::DefaultMaxInflightCommands);
	return _entityQueues[entityID] = std::move(eq);
}

+ (BOOL)isSupported {
	if ([NSProcessInfo instancesRespondToSelector:@selector(isOperatingSystemAtLeastVersion:)])
	{
		// Minimum required version is macOS 10.11.0 (El Capitan)
		return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:{ 10, 11, 0 }];
	}

	return FALSE;
}

/** std::string to NSString conversion */
+ (NSString*)getNSString:(std::string const&)cString {
	return [NSString stringWithCString:cString.c_str() encoding:NSUTF8StringEncoding];
}

/** NSString to std::string conversion */
+ (std::string)getStdString:(NSString*)nsString {
	return std::string{ [nsString UTF8String] };
}

+ (NSString*)getEntityCapabilities:(AVB17221Entity*)entity {
	return [NSString stringWithFormat:@"%@ %@ %@", (entity.talkerCapabilities & AVB17221ADPTalkerCapabilitiesImplemented) ? @"Talker" : @"", (entity.listenerCapabilities & AVB17221ADPListenerCapabilitiesImplemented) ? @"Listener" : @"", (entity.controllerCapabilities & AVB17221ADPControllerCapabilitiesImplemented) ? @"Controller" : @""];
}

- (void)startAsyncOperation {
	std::lock_guard<decltype(_lockPending)> const lg(_lockPending);
	_pendingCommands++;
}

- (void)stopAsyncOperation {
	{
		std::lock_guard<decltype(_lockPending)> const lg(_lockPending);
		AVDECC_ASSERT(_pendingCommands > 0, "Trying to stop async operation, but there is no pending operation");
		_pendingCommands--;
	}
	_pendingCondVar.notify_all();
}

- (void)waitAsyncOperations {
	// Wait for all remaining async operations to complete
	std::unique_lock<decltype(_lockPending)> sync_lg(_lockPending);
	_pendingCondVar.wait(sync_lg,
		[self]
		{
			return _pendingCommands == 0;
		});
	AVDECC_ASSERT(_pendingCommands == 0, "Waited for pending operations to complete, but there is some remaining one!");
}

- (std::optional<la::avdecc::entity::model::AvbInterfaceIndex>)getMatchingInterfaceIndex:(la::avdecc::entity::LocalEntity const&)entity {
	auto avbInterfaceIndex = std::optional<la::avdecc::entity::model::AvbInterfaceIndex>{ std::nullopt };
	auto const& macAddress = _protocolInterface->getMacAddress();

	for (auto const& [interfaceIndex, interfaceInfo] : entity.getInterfacesInformation())
	{
		if (interfaceInfo.macAddress == macAddress)
		{
			avbInterfaceIndex = interfaceIndex;
			break;
		}
	}

	return avbInterfaceIndex;
}

/** Initializer */
- (id)initWithInterfaceName:(NSString*)interfaceName andProtocolInterface:(la::avdecc::protocol::ProtocolInterfaceMacNativeImpl*)protocolInterface {
	self = [super init];
	if (self)
	{
		_primedDiscovery = FALSE;
		_protocolInterface = protocolInterface;
		_pendingCommands = 0u;
		self.interface = [[AVBEthernetInterface alloc] initWithInterfaceName:interfaceName];
		self.interface.entityDiscovery.discoveryDelegate = self;
	}
	return self;
}

/** Deinit method to shutdown every pending operations */
- (void)deinit {
	// Remove discovery delegate
	self.interface.entityDiscovery.discoveryDelegate = nil;

	decltype(_localProcessEntities) localProcessEntities;
	decltype(_registeredAcmpHandlers) registeredAcmpHandlers;
	// Move internal lists to temporary objects while locking, so we can safely cleanup outside of the lock
	{
		// Lock
		auto const lg = std::lock_guard{ _lock };
		localProcessEntities = std::move(_localProcessEntities);
		registeredAcmpHandlers = std::move(_registeredAcmpHandlers);
	}

	// Remove Local Entities that were not removed
	for (auto const& entityKV : localProcessEntities)
	{
		auto const& entity = entityKV.second;
		// Remove remaining handlers
		[self removeLocalProcessEntityHandlers:entity];
		// Disable advertising
		[self disableEntityAdvertising:entity];
	}

	// Remove ACMP handlers that were not removed
	for (auto const entityID : registeredAcmpHandlers)
	{
		[self deinitEntity:entityID];
	}

	// Wait for remaining pending operations
	[self waitAsyncOperations];

	// Release 1722.1 interface
	self.interface = nil;
}

/** Destructor */
- (void)dealloc {
	[self deinit];
#if !__has_feature(objc_arc)
	[super dealloc];
#endif
}

#pragma mark la::avdecc::protocol::ProtocolInterface bridge methods
- (la::avdecc::UniqueIdentifier)getDynamicEID {
	return [AVBCentralManager nextAvailableDynamicEntityID];
}

- (void)releaseDynamicEID:(la::avdecc::UniqueIdentifier)entityID {
	[AVBCentralManager releaseDynamicEntityID:entityID];
}

// Registration of a local process entity (an entity declared inside this process, not all local computer entities)
- (la::avdecc::protocol::ProtocolInterface::Error)registerLocalEntity:(la::avdecc::entity::LocalEntity&)entity {
	// Lock entities now, so we don't get interrupted during registration
	auto const lg = std::lock_guard{ _lock };

	auto const entityID = entity.getEntityID();

	// Entity is controller capable
	if (la::avdecc::utils::hasFlag(entity.getControllerCapabilities(), la::avdecc::entity::ControllerCapabilities::Implemented))
	{
		// Set a handler to monitor AECP Command messages
		if ([self.interface.aecp setCommandHandler:self forEntityID:entityID] == NO)
		{
			return la::avdecc::protocol::ProtocolInterface::Error::DuplicateLocalEntityID;
		}
		// Set a handler to monitor AECP Response messages, we are interested in unsolicited notifications and VendorUnique responses
		if ([self.interface.aecp setResponseHandler:self forControllerEntityID:entityID] == NO)
		{
			return la::avdecc::protocol::ProtocolInterface::Error::DuplicateLocalEntityID;
		}
	}
	// Other types are not supported right now
	else
	{
		return la::avdecc::protocol::ProtocolInterface::Error::InvalidEntityType;
	}

	// Add the entity to our cache of local entities declared by the running program
	_localProcessEntities.insert(decltype(_localProcessEntities)::value_type(entityID, entity));

	// Notify observers
	_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onLocalEntityOnline, _protocolInterface, entity);

	return la::avdecc::protocol::ProtocolInterface::Error::NoError;
}

// Remove handlers for a local process entity
- (void)removeLocalProcessEntityHandlers:(la::avdecc::entity::LocalEntity const&)entity {
	auto const entityID = entity.getEntityID();

	// Entity is controller capable
	if (la::avdecc::utils::hasFlag(entity.getControllerCapabilities(), la::avdecc::entity::ControllerCapabilities::Implemented))
	{
		// Remove handlers
		[self.interface.aecp removeCommandHandlerForEntityID:entityID];
		[self.interface.aecp removeResponseHandlerForControllerEntityID:entityID];
	}
}

// Unregistration of a local process entity
- (la::avdecc::protocol::ProtocolInterface::Error)unregisterLocalEntity:(la::avdecc::entity::LocalEntity const&)entity {
	auto const entityID = entity.getEntityID();

	// Remove handlers
	[self removeLocalProcessEntityHandlers:entity];

	// Disable advertising
	[self disableEntityAdvertising:entity];

	// Lock entities now that we have removed the handlers
	auto const lg = std::lock_guard{ _lock };

	// Remove the entity from our cache of local entities declared by the running program
	_localProcessEntities.erase(entityID);

	// Notify observers
	_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onLocalEntityOffline, _protocolInterface, entityID);

	return la::avdecc::protocol::ProtocolInterface::Error::NoError;
}

- (la::avdecc::protocol::ProtocolInterface::Error)setEntityNeedsAdvertise:(const la::avdecc::entity::LocalEntity&)entity flags:(la::avdecc::entity::LocalEntity::AdvertiseFlags)flags {
	NSError* error{ nullptr };

	// Change in GrandMaster
	if (flags.test(la::avdecc::entity::LocalEntity::AdvertiseFlag::GptpGrandmasterID))
	{
		auto const interfaceIndex = [self getMatchingInterfaceIndex:entity];
		if (!AVDECC_ASSERT_WITH_RET(interfaceIndex, "Should always have a matching AvbInterfaceIndex when this method is called"))
		{
			return la::avdecc::protocol::ProtocolInterface::Error::InvalidParameters;
		}

		auto const& interfaceInfo = entity.getInterfaceInformation(*interfaceIndex);
		if (interfaceInfo.gptpGrandmasterID)
		{
			[self.interface.entityDiscovery changeEntityWithEntityID:entity.getEntityID() toNewGPTPGrandmasterID:*interfaceInfo.gptpGrandmasterID error:&error];
			if (error != nullptr)
				return [FromNative getProtocolError:error];
		}
	}
	return la::avdecc::protocol::ProtocolInterface::Error::NoError;
}

- (la::avdecc::protocol::ProtocolInterface::Error)enableEntityAdvertising:(la::avdecc::entity::LocalEntity const&)entity {
	NSError* error{ nullptr };

	auto const interfaceIndex = [self getMatchingInterfaceIndex:entity];
	if (!AVDECC_ASSERT_WITH_RET(interfaceIndex, "Should always have a matching AvbInterfaceIndex when this method is called"))
	{
		return la::avdecc::protocol::ProtocolInterface::Error::InvalidParameters;
	}

	[self.interface.entityDiscovery addLocalEntity:[ToNative makeAVB17221Entity:entity interfaceIndex:*interfaceIndex] error:&error];
	if (error != nullptr)
		return [FromNative getProtocolError:error];

	return la::avdecc::protocol::ProtocolInterface::Error::NoError;
}

- (la::avdecc::protocol::ProtocolInterface::Error)disableEntityAdvertising:(la::avdecc::entity::LocalEntity const&)entity {
	NSError* error{ nullptr };

	[self.interface.entityDiscovery removeLocalEntity:entity.getEntityID() error:&error];
	if (error != nullptr)
		return [FromNative getProtocolError:error];

	return la::avdecc::protocol::ProtocolInterface::Error::NoError;
}

- (BOOL)discoverRemoteEntities {
	if (!_primedDiscovery)
	{
		[self.interface.entityDiscovery primeIterators];
		_primedDiscovery = TRUE;
		return TRUE;
	}
	return [self.interface.entityDiscovery discoverEntities];
}

- (BOOL)discoverRemoteEntity:(la::avdecc::UniqueIdentifier)entityID {
	if (!_primedDiscovery)
	{
		[self.interface.entityDiscovery primeIterators];
		_primedDiscovery = TRUE;
		return TRUE;
	}
	return [self.interface.entityDiscovery discoverEntity:entityID];
}

- (la::avdecc::protocol::ProtocolInterface::Error)sendAecpCommand:(la::avdecc::protocol::Aecpdu::UniquePointer&&)aecpdu handler:(la::avdecc::protocol::ProtocolInterface::AecpCommandResultHandler const&)onResult {
	auto const macAddr = aecpdu->getDestAddress(); // Make a copy of the target macAddress so it can safely be used inside the objC block
	__block auto resultHandler = onResult; // Make a copy of the handler so it can safely be used inside the objC block. Declare it as __block so we can modify it from the block (to fix a bug that macOS sometimes call the completionHandler twice)

	auto message = [ToNative makeAecpMessage:*aecpdu];
	if (message != NULL)
	{
		decltype(EntityQueues::aecpQueue) queue;
		// Only take the lock while searching for the queue, we want to release it before invoking dispath_async to prevent a deadlock
		{
			std::lock_guard<decltype(_lockQueues)> const lg(_lockQueues);
			auto eqIt = _entityQueues.find(message.targetEntityID);
			if (eqIt == _entityQueues.end())
			{
				queue = [self createQueuesForRemoteEntity:message.targetEntityID].aecpQueue;
			}
			else
			{
				queue = eqIt->second.aecpQueue;
			}
		}

		dispatch_async(queue, ^{
			dispatch_semaphore_t limiter;
			{
				std::lock_guard<decltype(_lockQueues)> const lg(_lockQueues);
				auto eqIt = _entityQueues.find(message.targetEntityID);
				if (eqIt == _entityQueues.end())
				{
					// Entity no longer registered, ignore this command and return
					return;
				}
				limiter = eqIt->second.aecpLimiter; // We can store the limiter here, we know the queue and semaphore exists until all scheduled blocks on this queue are finished (thanks to the dispatch_sync call)
			}

			// Take a semaphore count to limit the inflight commands
			dispatch_semaphore_wait(limiter, DISPATCH_TIME_FOREVER);

			[self startAsyncOperation];
			[self.interface.aecp sendCommand:message
													toMACAddress:[ToNative makeAVBMacAddress:macAddr]
										 completionHandler:^(NSError* error, AVB17221AECPMessage* message) {
											 if (!resultHandler)
											 {
												 LOG_PROTOCOL_INTERFACE_DEBUG(la::avdecc::networkInterface::MacAddress{}, la::avdecc::networkInterface::MacAddress{}, "AECP completionHandler called again with same result message, ignoring this call.");
												 return;
											 }
											 {
												 // Lock Self before calling a handler, we come from a network thread
												 auto const lg = std::lock_guard{ _lock };
												 if (kIOReturnSuccess == (IOReturn)error.code)
												 {
													 // Special case for VendorUnique messages:
													 //  It's up to the implementation to keep track of the message, the response, the timeout, the retry.
													 //  This completion handler is called immediately upon send, with NSError set if there was an error.
													 //  Otherwise we arrive here with the exact sent message passed here so we can retrieve the sequenceID to track the response in - (BOOL)AECPDidReceiveResponse:(AVB17221AECPMessage*)message onInterface:(AVB17221AECPInterface*)anInterface;
													 if (message.messageType == AVB17221AECPMessageTypeVendorUniqueCommand)
													 {
														 // Right now, due to a bug in AECPDidReceiveResponse not being triggered, just act as if the message had time out
														 la::avdecc::utils::invokeProtectedHandler(resultHandler, nullptr, la::avdecc::protocol::ProtocolInterface::Error::Timeout);
													 }
													 else
													 {
														 auto aecpdu = [FromNative makeAecpdu:message toDestAddress:_protocolInterface->getMacAddress()];
														 la::avdecc::utils::invokeProtectedHandler(resultHandler, aecpdu.get(), la::avdecc::protocol::ProtocolInterface::Error::NoError);
													 }
												 }
												 else
												 {
													 la::avdecc::utils::invokeProtectedHandler(resultHandler, nullptr, [FromNative getProtocolError:error]);
												 }
											 }
											 resultHandler = {}; // Clear resultHandler in case this completionHandler is called twice (bug in macOS)
											 [self stopAsyncOperation];
											 // Signal the semaphore so we can process another command
											 dispatch_semaphore_signal(limiter);
										 }]; // We don't care about the method result, the completionHandler will always be called anyway (if for some reason, we detect it's not always the case, simply remove the resultHandler and call stopAsyncOperation and signal the semaphore if the method fails, and return TransportError. Carefull to change the resultHandler under a small lock that has to be shared with the block as well)
		});
	}
	else
	{
		AVDECC_ASSERT(false, "Not supported AECP message type");
		return la::avdecc::protocol::ProtocolInterface::Error::InternalError;
	}
	return la::avdecc::protocol::ProtocolInterface::Error::NoError;
}

- (la::avdecc::protocol::ProtocolInterface::Error)sendAecpResponse:(la::avdecc::protocol::Aecpdu::UniquePointer&&)aecpdu {
	auto const macAddr = aecpdu->getDestAddress(); // Make a copy of the target macAddress so it can safely be used inside the objC block

	auto message = [ToNative makeAecpMessage:*aecpdu];
	if (message != NULL)
	{
		decltype(EntityQueues::aecpQueue) queue;
		// Only take the lock while searching for the queue, we want to release it before invoking dispath_async to prevent a deadlock
		{
			std::lock_guard<decltype(_lockQueues)> const lg(_lockQueues);
			auto eqIt = _entityQueues.find(message.controllerEntityID);
			if (eqIt == _entityQueues.end())
			{
				queue = [self createQueuesForRemoteEntity:message.controllerEntityID].aecpQueue;
			}
			else
			{
				queue = eqIt->second.aecpQueue;
			}
		}

		dispatch_async(queue, ^{
			dispatch_semaphore_t limiter;
			{
				std::lock_guard<decltype(_lockQueues)> const lg(_lockQueues);
				auto eqIt = _entityQueues.find(message.controllerEntityID);
				if (eqIt == _entityQueues.end())
				{
					// Entity no longer registered, ignore this command and return
					return;
				}
				limiter = eqIt->second.aecpLimiter; // We can store the limiter here, we know the queue and semaphore exists until all scheduled blocks on this queue are finished (thanks to the dispatch_sync call)
			}

			// Take a semaphore count to limit the inflight commands
			dispatch_semaphore_wait(limiter, DISPATCH_TIME_FOREVER);

			// Actually send the message
			[self startAsyncOperation];
			[self.interface.aecp sendResponse:message toMACAddress:[ToNative makeAVBMacAddress:macAddr] error:Nil];
			[self stopAsyncOperation];

			// Signal the semaphore so we can process another command
			dispatch_semaphore_signal(limiter);
		});
	}
	else
	{
		AVDECC_ASSERT(false, "Not supported AECP message type");
		return la::avdecc::protocol::ProtocolInterface::Error::InternalError;
	}
	return la::avdecc::protocol::ProtocolInterface::Error::NoError;
}

- (la::avdecc::protocol::ProtocolInterface::Error)sendAcmpCommand:(la::avdecc::protocol::Acmpdu::UniquePointer&&)acmpdu handler:(la::avdecc::protocol::ProtocolInterface::AcmpCommandResultHandler const&)onResult {
	__block auto resultHandler = onResult; // Make a copy of the handler so it can safely be used inside the objC block. Declare it as __block so we can modify it from the block (to fix a bug that macOS sometimes call the completionHandler twice)

	auto const& acmp = static_cast<la::avdecc::protocol::Acmpdu const&>(*acmpdu);
	auto const message = [[AVB17221ACMPMessage alloc] init];
#if !__has_feature(objc_arc)
	[message autorelease];
#endif
	// Set Acmp fields
	message.messageType = static_cast<AVB17221ACMPMessageType>(acmp.getMessageType().getValue());
	message.status = AVB17221ACMPStatusSuccess;
	message.streamID = acmp.getStreamID();
	message.controllerEntityID = acmp.getControllerEntityID();
	message.talkerEntityID = acmp.getTalkerEntityID();
	message.talkerUniqueID = acmp.getTalkerUniqueID();
	message.listenerEntityID = acmp.getListenerEntityID();
	message.listenerUniqueID = acmp.getListenerUniqueID();
	message.destinationMAC = [ToNative makeAVBMacAddress:acmp.getStreamDestAddress()];
	message.connectionCount = acmp.getConnectionCount();
	message.sequenceID = acmp.getSequenceID();
	message.flags = static_cast<AVB17221ACMPFlags>(acmp.getFlags());
	message.vlanID = acmp.getStreamVlanID();

	[self startAsyncOperation];
	[self.interface.acmp sendACMPCommandMessage:message
														completionHandler:^(NSError* error, AVB17221ACMPMessage* message) {
															if (!resultHandler)
															{
																LOG_PROTOCOL_INTERFACE_DEBUG(la::avdecc::networkInterface::MacAddress{}, la::avdecc::networkInterface::MacAddress{}, "ACMP completionHandler called again with same result message, ignoring this call.");
																return;
															}
															{
																// Lock Self before calling a handler, we come from a network thread
																auto const lg = std::lock_guard{ _lock };
																if (kIOReturnSuccess == (IOReturn)error.code)
																{
																	auto acmp = [FromNative makeAcmpdu:message];
																	la::avdecc::utils::invokeProtectedHandler(resultHandler, acmp.get(), la::avdecc::protocol::ProtocolInterface::Error::NoError);
																}
																else
																{
																	la::avdecc::utils::invokeProtectedHandler(resultHandler, nullptr, [FromNative getProtocolError:error]);
																}
															}
															resultHandler = {}; // Clear resultHandler in case this completionHandler is called twice (bug in macOS)
															[self stopAsyncOperation];
														}]; // We don't care about the method result, the completionHandler will always be called anyway (if for some reason, we detect it's not always the case, simply remove the resultHandler and call stopAsyncOperation if the method fails, and return TransportError. Carefull to change the resultHandler under a small lock that has to be shared with the block as well)
	return la::avdecc::protocol::ProtocolInterface::Error::NoError;
}

- (void)lock {
	_lock.lock();
}

- (void)unlock {
	_lock.unlock();
}

- (bool)isSelfLocked {
	return _lock.isSelfLocked();
}

#pragma mark AVB17221EntityDiscoveryDelegate delegate
- (void)initEntity:(la::avdecc::UniqueIdentifier)entityID {
	// Register ACMP sniffing handler for this entity
	if ([self.interface.acmp setHandler:self forEntityID:entityID])
	{
		// Register the entity for handler removal upon shutdown
		auto const lg = std::lock_guard{ _lock };
		_registeredAcmpHandlers.insert(entityID);
	}

	// Create queues and semaphore
	{
		std::lock_guard<decltype(_lockQueues)> const lg(_lockQueues);
		[self createQueuesForRemoteEntity:entityID];
	}
}

- (void)deinitEntity:(la::avdecc::UniqueIdentifier)entityID {
	{
		// Lock
		auto const lg = std::lock_guard{ _lock };

		// Unregister ACMP handler
		_registeredAcmpHandlers.erase(entityID);
		[self.interface.acmp removeHandlerForEntityID:entityID];
	}

	// Remove the EntityQueues structure from the map under the lock (if found), then clean it without the lock (to prevent deadlock)
	EntityQueues eq;
	bool foundEq{ false };
	{
		std::lock_guard<decltype(_lockQueues)> const lg(_lockQueues);
		auto eqIt = _entityQueues.find(entityID);
		if (eqIt != _entityQueues.end())
		{
			eq = eqIt->second; // Copy the structure now, we will remove it from the map next line (if ARC is enabled, a ref count will be taken. If not we still haven't call dispatch_release so the object is still valid)
			//NSLog(@"Queue retain count before sync: %ld", eq.aecpQueue.retainCount);
			//NSLog(@"Limiter retain count before sync: %ld", eq.aecpLimiter.retainCount);

			// Remove from the map to indicate it's being removed
			_entityQueues.erase(entityID);

			// We found it, we can clean it up
			foundEq = true;
		}
	}

	// Found a matching EntityQueues for the entity, time to clean it up
	if (foundEq)
	{
		// Synchronize the queue using an empty block
		dispatch_sync(eq.aecpQueue, ^{
										//NSLog(@"Queue retain count: %ld", eq.aecpQueue.retainCount);
										//NSLog(@"Limiter retain count: %ld", eq.aecpLimiter.retainCount);
									});
#if !__has_feature(objc_arc)
		// Release the objects
		dispatch_release(eq.aecpQueue);
		dispatch_release(eq.aecpLimiter);
#endif
	}
}

// Notification of an arriving local computer entity
- (void)didAddLocalEntity:(AVB17221Entity*)newEntity on17221EntityDiscovery:(AVB17221EntityDiscovery*)entityDiscovery {
	[self initEntity:newEntity.entityID];

	// Lock
	auto const lg = std::lock_guard{ _lock };

	// Notify observers
	auto e = [FromNative makeEntity:newEntity];
	_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onLocalEntityOnline, _protocolInterface, e);
}

// Notification of a departing local computer entity
- (void)didRemoveLocalEntity:(AVB17221Entity*)oldEntity on17221EntityDiscovery:(AVB17221EntityDiscovery*)entityDiscovery {
	[self deinitEntity:oldEntity.entityID];

	// Lock
	auto const lg = std::lock_guard{ _lock };

	// Notify observers
	_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onLocalEntityOffline, _protocolInterface, oldEntity.entityID);
}

- (void)didRediscoverLocalEntity:(AVB17221Entity*)entity on17221EntityDiscovery:(AVB17221EntityDiscovery*)entityDiscovery {
	// Check if Entity already in the list
	{
		// Lock
		auto const lg = std::lock_guard{ _lock };
		if (_registeredAcmpHandlers.find(entity.entityID) == _registeredAcmpHandlers.end())
		{
			AVDECC_ASSERT(false, "didRediscoverLocalEntity: Entity not registered... I thought Rediscover was called when an entity announces itself again without any change in it's ADP info... Maybe simply call didAddLocalEntity");
			return;
		}
	}
	// Nothing to do, entity has already been detected
}

- (void)didUpdateLocalEntity:(AVB17221Entity*)entity changedProperties:(AVB17221EntityPropertyChanged)changedProperties on17221EntityDiscovery:(AVB17221EntityDiscovery*)entityDiscovery {
	constexpr NSUInteger ignoreChangeMask = 0xFFFFFFFF & ~(AVB17221EntityPropertyChangedTimeToLive | AVB17221EntityPropertyChangedAvailableIndex);
	// If changes are only for flags we want to ignore, return
	if ((changedProperties & ignoreChangeMask) == 0)
		return;

	auto e = [FromNative makeEntity:entity];

	// Lock
	auto const lg = std::lock_guard{ _lock };

	// If a change occured in a forbidden flag, simulate offline/online for this entity
	if ((changedProperties & kAVB17221EntityPropertyChangedShouldntChangeMask) != 0)
	{
		_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onLocalEntityOffline, _protocolInterface, e.getEntityID());
		_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onLocalEntityOnline, _protocolInterface, e);
	}
	else
	{
		_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onLocalEntityUpdated, _protocolInterface, e);
	}
}

- (void)didAddRemoteEntity:(AVB17221Entity*)newEntity on17221EntityDiscovery:(AVB17221EntityDiscovery*)entityDiscovery {
	[self initEntity:newEntity.entityID];

	// Lock
	auto const lg = std::lock_guard{ _lock };

	// Add entity to available index list
	auto previousResult = _lastAvailableIndex.insert(std::make_pair(newEntity.entityID, newEntity.availableIndex));
	if (!AVDECC_ASSERT_WITH_RET(previousResult.second, "Adding a new entity but it's already in the available index list"))
	{
		previousResult.first->second = newEntity.availableIndex;
	}

	// Notify observers
	auto e = [FromNative makeEntity:newEntity];
	_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onRemoteEntityOnline, _protocolInterface, e);
}

- (void)didRemoveRemoteEntity:(AVB17221Entity*)oldEntity on17221EntityDiscovery:(AVB17221EntityDiscovery*)entityDiscovery {
	[self deinitEntity:oldEntity.entityID];

	// Lock
	auto const lg = std::lock_guard{ _lock };

	// Clear entity from available index list
	_lastAvailableIndex.erase(oldEntity.entityID);

	// Notify observers
	_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onRemoteEntityOffline, _protocolInterface, oldEntity.entityID);
}

- (void)didRediscoverRemoteEntity:(AVB17221Entity*)entity on17221EntityDiscovery:(AVB17221EntityDiscovery*)entityDiscovery {
	// Check if Entity already in the list
	{
		// Lock
		auto const lg = std::lock_guard{ _lock };
		if (_registeredAcmpHandlers.find(entity.entityID) == _registeredAcmpHandlers.end())
		{
			AVDECC_ASSERT(false, "didRediscoverRemoteEntity: Entity not registered... I thought Rediscover was called when an entity announces itself again without any change in it's ADP info... Maybe simply call didAddRemoteEntity");
			return;
		}
	}
	// Nothing to do, entity has already been detected
}

- (void)didUpdateRemoteEntity:(AVB17221Entity*)entity changedProperties:(AVB17221EntityPropertyChanged)changedProperties on17221EntityDiscovery:(AVB17221EntityDiscovery*)entityDiscovery {
	// Lock
	auto const lg = std::lock_guard{ _lock };

	// Check for an invalid change in AvailableIndex
	if ((changedProperties & AVB17221EntityPropertyChangedAvailableIndex) != 0)
	{
		auto previousIndexIt = _lastAvailableIndex.find(entity.entityID);
		if (previousIndexIt == _lastAvailableIndex.end())
		{
			AVDECC_ASSERT(previousIndexIt != _lastAvailableIndex.end(), "didUpdateRemoteEntity called but entity is unknown");
			_lastAvailableIndex.insert(std::make_pair(entity.entityID, entity.availableIndex));
		}
		else
		{
			auto const previousIndex = previousIndexIt->second; // Get previous index
			previousIndexIt->second = entity.availableIndex; // Update index value with the latest one

			if (previousIndex >= entity.availableIndex)
			{
				auto e = [FromNative makeEntity:entity];
				_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onRemoteEntityOffline, _protocolInterface, e.getEntityID());
				_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onRemoteEntityOnline, _protocolInterface, e);
				return;
			}
		}
	}

	constexpr NSUInteger ignoreChangeMask = 0xFFFFFFFF & ~(AVB17221EntityPropertyChangedTimeToLive | AVB17221EntityPropertyChangedAvailableIndex);
	// If changes are only for flags we want to ignore, return
	if ((changedProperties & ignoreChangeMask) == 0)
		return;

	auto e = [FromNative makeEntity:entity];

	// If a change occured in a forbidden flag, simulate offline/online for this entity
	if ((changedProperties & kAVB17221EntityPropertyChangedShouldntChangeMask) != 0)
	{
		_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onRemoteEntityOffline, _protocolInterface, e.getEntityID());
		_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onRemoteEntityOnline, _protocolInterface, e);
	}
	else
	{
		_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onRemoteEntityUpdated, _protocolInterface, e);
	}
}

#pragma mark AVB17221AECPClient delegate
- (BOOL)AECPDidReceiveCommand:(AVB17221AECPMessage*)message onInterface:(AVB17221AECPInterface*)anInterface {
	// This handler is called for all AECP commands targeting one of our registered Entities

	// Lock
	auto const lg = std::lock_guard{ _lock };

	// Only process it if it's targeted to a registered LocalEntity
	if (_localProcessEntities.count([message targetEntityID]) == 0)
		return NO;

	auto const aecpdu = [FromNative makeAecpdu:message toDestAddress:_protocolInterface->getMacAddress()];

	// Notify the observers
	_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onAecpCommand, _protocolInterface, *aecpdu);

	return YES;
}

- (BOOL)AECPDidReceiveResponse:(AVB17221AECPMessage*)message onInterface:(AVB17221AECPInterface*)anInterface {
	// This handler is called for all AECP responses targeting one of our registered Entities, even the messages that are solicited responses and which will be handled by the block of aecp.sendCommand() method

	// Lock
	auto const lg = std::lock_guard{ _lock };

	// Search our local entities, which should be found!
	if (_localProcessEntities.count([message controllerEntityID]) == 0)
		return NO;

	auto const aecpdu = [FromNative makeAecpdu:message toDestAddress:_protocolInterface->getMacAddress()];

	// Special case for Unsolicited Responses
	if ([message messageType] == AVB17221AECPMessageTypeAEMResponse && [static_cast<AVB17221AECPAEMMessage*>(message) isUnsolicited])
	{
		// Notify the observers
		_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onAecpAemUnsolicitedResponse, _protocolInterface, *aecpdu);
		return YES;
	}

	// Ignore all other messages in this handler, expected responses will be handled by the block of aecp.sendCommand() method
	return NO;
}

#pragma mark AVB17221ACMPClient delegate
- (BOOL)ACMPDidReceiveCommand:(AVB17221ACMPMessage*)message onInterface:(AVB17221ACMPInterface*)anInterface {
	// This handler is called for all ACMP messages, even the messages that are sent by ourself

	// Lock
	auto const lg = std::lock_guard{ _lock };

	auto const acmpdu = [FromNative makeAcmpdu:message];

	// Notify the observers
	_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onAcmpCommand, _protocolInterface, *acmpdu);

	return YES;
}

- (BOOL)ACMPDidReceiveResponse:(AVB17221ACMPMessage*)message onInterface:(AVB17221ACMPInterface*)anInterface {
	// This handler is called for all ACMP messages, even the messages that are expected responses and which will be handled by the block of acmp.sendACMPCommandMessage() method

	// Lock
	auto const lg = std::lock_guard{ _lock };

	auto const acmpdu = [FromNative makeAcmpdu:message];

	// Notify the observers
	_protocolInterface->notifyObserversMethod<la::avdecc::protocol::ProtocolInterface::Observer>(&la::avdecc::protocol::ProtocolInterface::Observer::onAcmpResponse, _protocolInterface, *acmpdu);

	return YES;
}

@end
